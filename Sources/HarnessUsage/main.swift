import AppKit
import HarnessUsageCore

if CommandLine.arguments.contains("--dump") {
    await runDump()
    exit(0)
}
if CommandLine.arguments.contains("--no-login") {
    exit(LoginItem.setEnabled(false) ? 0 : 1)
}

// Accessory app: no Dock icon, no main window.
let appDelegate = AppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate
app.setActivationPolicy(.accessory)

// An accessory app shows no menu bar of its own, but key equivalents still route through
// `mainMenu` while one of its windows is key. Without this, ⌘Q in Settings does nothing and the
// only way out is the notch's right-click menu.
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Harness Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let appMenuItem = NSMenuItem()
appMenuItem.submenu = appMenu
let mainMenu = NSMenu()
mainMenu.addItem(appMenuItem)
app.mainMenu = mainMenu

app.run()
