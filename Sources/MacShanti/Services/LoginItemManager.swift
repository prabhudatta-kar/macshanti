import Foundation
import ServiceManagement

/// Wraps `SMAppService` (macOS 13+) so MacShanti can register itself as a login
/// item and launch automatically at sign-in. The user can toggle this from the
/// popover; we only auto-enable once (on first ever launch) so we never override
/// a later opt-out.
enum LoginItemManager {

    private static let firstLaunchKey = "didConfigureLoginItem"

    /// True if the app is currently set to open at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Enable or disable "open at login".
    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MacShanti: login item \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }

    /// On the very first launch, turn autostart on by default. Subsequent
    /// launches respect whatever the user has since chosen.
    static func configureOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: firstLaunchKey) else { return }
        defaults.set(true, forKey: firstLaunchKey)
        set(true)
    }
}
