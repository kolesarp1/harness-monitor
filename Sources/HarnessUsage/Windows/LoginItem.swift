import Foundation
import ServiceManagement

// Launch-at-login via SMAppService, which keys a login item on the bundle's code signature AND its
// recorded path: it only relaunches an app from an /Applications location, so registering from a dev
// build path reports success and then never launches anything. SMAppService is also the store of
// record — there is no persisted copy of this flag anywhere in Settings, because a copy could only ever
// drift from what System Settings ▸ Login Items actually holds.
enum LoginItem {
    // Pure, so the location gate is checkable without a bundle. The bundle must be an `.app` living
    // *under* /Applications or ~/Applications. Both halves carry weight: a lookalike path (e.g.
    // ~/Desktop/Applications) fails the root test, and a loose executable fails the `.app` test —
    // `Bundle.main.bundlePath` for a non-bundled binary is only its enclosing directory, so a toolchain
    // helper hosting `swift test` reports a path under /Applications/Xcode.app and would otherwise
    // clear the root test on its own.
    static func installed(bundlePath: String) -> Bool {
        let url = URL(fileURLWithPath: bundlePath).standardizedFileURL
        guard url.pathExtension == "app" else { return false }
        let allowedRoots = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications"),
        ].map(\.standardizedFileURL.path)
        return allowedRoots.contains { url.path.hasPrefix($0 + "/") }
    }

    // Why the login item cannot be registered right now, or nil when it can. Surfaced in Settings: a
    // switch that silently does nothing is worse than one that says why it is off.
    static var unavailableReason: String? {
        installed(bundlePath: Bundle.main.bundlePath) ? nil : "Move Harness Usage to /Applications to enable this."
    }

    static var isRegistered: Bool { SMAppService.mainApp.status == .enabled }

    // True when the change was applied. Callers must trust this rather than re-reading `status`: the
    // status settles asynchronously, so a read taken straight after `register()` can still say
    // `.notRegistered` and talk the caller into undoing the registration it just made.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        guard unavailableReason == nil else { return false }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            if isAlreadyInRequestedState(error, on: on) { return true }
            FileHandle.standardError.write(
                Data("HarnessUsage: login item \(on ? "register" : "unregister") failed: \(error)\n".utf8))
            return false
        }
    }

    // "Already in the state you asked for" is success, not failure. `SMAppService.h` documents both:
    // unregistering a service that was never registered throws `kSMErrorJobNotFound`, and registering
    // one that already is throws `kSMErrorAlreadyRegistered`. Treating the first as a failure made
    // `--no-login` exit 1 on a Mac that had never enabled the item, which aborted `make uninstall`
    // before it could kill the app or remove the bundle — and showed "macOS refused the change" under
    // a switch the user had just turned off.
    private static func isAlreadyInRequestedState(_ error: any Error, on: Bool) -> Bool {
        (error as NSError).code == (on ? kSMErrorAlreadyRegistered : kSMErrorJobNotFound)
    }
}
