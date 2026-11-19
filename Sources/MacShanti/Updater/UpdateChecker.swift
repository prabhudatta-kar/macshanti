import AppKit
import Foundation

/// Checks GitHub Releases for a newer MacShanti build and can download and
/// install it in place.
///
/// Release contract (see Scripts/make_release.sh): every release publishes a
/// tag `vX.Y.Z` with a zipped app attached as an asset named exactly
/// "MacShanti.zip". This class polls the "latest release" REST endpoint,
/// compares the tag against the running bundle's CFBundleShortVersionString,
/// downloads the zip with URLSession (no quarantine xattr, so the ad-hoc
/// signed replacement launches without a Gatekeeper prompt), swaps the .app
/// bundle in place, and relaunches through a detached helper script.
///
/// All state changes are published on the main queue for SwiftUI.
final class UpdateChecker: ObservableObject {

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    /// URL of the release page, kept so the UI can offer a manual fallback
    /// after a failed automatic install.
    private(set) var releasePageURL: URL?

    private static let apiURL = URL(string: "https://api.github.com/repos/prabhudatta-kar/macshanti/releases/latest")!
    private static let assetName = "MacShanti.zip"
    private static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    private var timer: Timer?
    private var latest: Release?

    private struct Release {
        let version: String   // tag without the leading "v"
        let pageURL: URL
        let assetURL: URL?
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Checks once on launch and then once a day. Call once after startup.
    func startAutomaticChecks() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Self.autoCheckInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    // MARK: - Check

    func check() {
        switch status {
        case .checking, .downloading, .installing:
            return
        default:
            break
        }
        status = .checking

        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacShanti/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.status = .failed("Update check failed: \(error.localizedDescription)")
                    return
                }
                let http = response as? HTTPURLResponse
                // 404 = no release has been published yet; treat as up to date.
                if http?.statusCode == 404 {
                    self.status = .upToDate
                    return
                }
                guard http?.statusCode == 200, let data else {
                    self.status = .failed("Update check failed (HTTP \(http?.statusCode ?? -1)).")
                    return
                }
                do {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let tag = json["tag_name"] as? String,
                          let page = json["html_url"] as? String,
                          let pageURL = URL(string: page) else {
                        throw UpdateError.unexpectedResponse
                    }
                    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                    let assets = json["assets"] as? [[String: Any]] ?? []
                    let assetURL = assets
                        .first { ($0["name"] as? String) == Self.assetName }
                        .flatMap { $0["browser_download_url"] as? String }
                        .flatMap(URL.init(string:))
                    let release = Release(version: version, pageURL: pageURL, assetURL: assetURL)
                    self.releasePageURL = pageURL

                    if Self.isNewer(version, than: self.currentVersion) {
                        self.latest = release
                        self.status = .available(version: version)
                    } else {
                        self.latest = nil
                        self.status = .upToDate
                    }
                } catch {
                    self.status = .failed("Could not read the update response.")
                }
            }
        }.resume()
    }

    /// Numeric semver-ish comparison: "1.10.0" > "1.9.0". Missing components
    /// count as 0 and non-numeric components as 0, so odd tags degrade to
    /// "no update" rather than a wrong install.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Install

    /// Downloads the pending release and swaps it in for the running app.
    /// Only works from an installed .app bundle the user can write; anything
    /// else fails with a message pointing at the manual path.
    func installAvailableUpdate() {
        guard case .available = status, let release = latest else { return }

        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            fail("MacShanti is running from a build directory, not /Applications. Update with git pull + make_app.sh instead.", openPage: false)
            return
        }
        guard FileManager.default.isWritableFile(atPath: appURL.path) else {
            fail("MacShanti can't replace \(appURL.path) (no write permission). Download the update manually instead.", openPage: true)
            return
        }
        guard let assetURL = release.assetURL else {
            fail("The v\(release.version) release has no \(Self.assetName) attached. Download it from the release page instead.", openPage: true)
            return
        }

        status = .downloading
        URLSession.shared.downloadTask(with: assetURL) { [weak self] tmp, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.fail("Download failed: \(error.localizedDescription)", openPage: true)
                    return
                }
                guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self.fail("Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)).", openPage: true)
                    return
                }
                self.status = .installing
                do {
                    try self.swapIn(downloadedZip: tmp, expectingVersion: release.version, appURL: appURL)
                } catch {
                    self.fail("Install failed: \(error.localizedDescription) The release page has a manual download.", openPage: true)
                }
            }
        }.resume()
    }

    /// Unzips the download, sanity-checks it, moves the running app aside, puts
    /// the new one in its place, and relaunches. Throwing anywhere before the
    /// swap leaves the installed app untouched; a failed swap is rolled back.
    private func swapIn(downloadedZip: URL, expectingVersion version: String, appURL: URL) throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("MacShanti-update-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        let zip = workDir.appendingPathComponent(Self.assetName)
        try fm.moveItem(at: downloadedZip, to: zip)

        // ditto is the reliable way to unzip an archived .app (preserves
        // symlinks and resource forks, applies no quarantine).
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, workDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw UpdateError.unzipFailed
        }

        let newApp = workDir.appendingPathComponent("MacShanti.app")
        guard fm.fileExists(atPath: newApp.path) else {
            throw UpdateError.bundleMissing
        }

        // Sanity check: the downloaded bundle really is the version we asked
        // for, so a stale or mismatched asset can never silently replace us.
        let plistURL = newApp.appendingPathComponent("Contents/Info.plist")
        let plist = NSDictionary(contentsOf: plistURL) as? [String: Any]
        guard (plist?["CFBundleShortVersionString"] as? String) == version else {
            throw UpdateError.versionMismatch
        }

        // Swap. Moving a running .app is allowed on macOS; the old binary keeps
        // running from its inode until we quit.
        let backup = appURL.deletingLastPathComponent()
            .appendingPathComponent("MacShanti-backup-\(ProcessInfo.processInfo.processIdentifier).app")
        try? fm.removeItem(at: backup)
        do {
            try fm.moveItem(at: appURL, to: backup)
            do {
                try fm.moveItem(at: newApp, to: appURL)
            } catch {
                // Roll back so the user is never left without an app.
                try? fm.moveItem(at: backup, to: appURL)
                throw error
            }
        }

        // Relaunch: a detached helper waits for this process to exit, then
        // opens the new bundle (plain `open` now would just re-activate the
        // running instance) and cleans up the backup and itself.
        let helper = workDir.appendingPathComponent("relaunch.sh")
        let script = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        sleep 0.5
        open "\(appURL.path)"
        rm -rf "\(backup.path)"
        rm -rf "\(workDir.path)"
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/bash")
        relauncher.arguments = [helper.path]
        try relauncher.run()

        NSApp.terminate(nil)
    }

    private func fail(_ message: String, openPage: Bool) {
        status = .failed(message)
        if openPage, let url = releasePageURL {
            NSWorkspace.shared.open(url)
        }
    }

    private enum UpdateError: LocalizedError {
        case unexpectedResponse
        case unzipFailed
        case bundleMissing
        case versionMismatch

        var errorDescription: String? {
            switch self {
            case .unexpectedResponse: return "Unexpected response from GitHub."
            case .unzipFailed: return "The downloaded update would not unzip."
            case .bundleMissing: return "The download did not contain MacShanti.app."
            case .versionMismatch: return "The download was not the expected version."
            }
        }
    }
}
