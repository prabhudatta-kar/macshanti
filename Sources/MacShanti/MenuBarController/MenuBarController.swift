import AppKit
import SwiftUI
import Combine

/// Manages the `NSStatusItem` (colored dot) and a SwiftUI popover. The dot's
/// color tracks memory pressure; clicking it toggles the popover. Owns the
/// popover's actions: quitting a target app, recording "never suggest", and
/// asking the monitor to re-sample immediately.
final class MenuBarController: NSObject, NSPopoverDelegate {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let state: MonitorState
    private let preferences: PreferenceStore
    private let onRefresh: () -> Void
    private var cancellable: AnyCancellable?

    init(state: MonitorState, preferences: PreferenceStore, onRefresh: @escaping () -> Void) {
        self.state = state
        self.preferences = preferences
        self.onRefresh = onRefresh
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()

        cancellable = state.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.updateDot(pressure: snapshot?.pressure ?? .normal)
            }
        updateDot(pressure: .normal)
    }

    private func configureButton() {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "MacShanti — memory pressure"
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self

        let root = PopoverView(
            state: state,
            onQuitApp: { [weak self] pid in self?.quitApp(pid: pid) },
            onNeverSuggest: { [weak self] name in self?.neverSuggest(name) },
            onQuitSelf: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingController(rootView: root)
        // Let the popover grow/shrink to fit the SwiftUI content (the number of
        // recommendations varies).
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    // MARK: - Actions

    private func quitApp(pid: Int32) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        }
        // Re-sample shortly so the popover reflects the freed memory.
        refreshSoon()
    }

    private func neverSuggest(_ name: String) {
        preferences.setNeverSuggest(name, true)
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.onRefresh()
        }
    }

    // MARK: - Menubar dot

    /// Draw a filled circle in the pressure color as a (non-template) image so
    /// the menubar preserves the green/yellow/red tint.
    private func updateDot(pressure: PressureLevel) {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 2, dy: 2)
            pressure.nsColor.setFill()
            NSBezierPath(ovalIn: inset).fill()
            return true
        }
        image.isTemplate = false
        statusItem.button?.image = image
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
