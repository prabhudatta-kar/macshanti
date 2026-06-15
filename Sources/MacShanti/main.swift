import AppKit

// MacShanti is a menubar-only (accessory) application. We bootstrap AppKit
// manually rather than using @main / NSApplicationMain so that we can run as
// an .accessory app (no Dock icon) even before an Info.plist is present.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
