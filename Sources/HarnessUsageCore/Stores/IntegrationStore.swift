import Foundation
import Observation

// Which integrations are present on this machine. Drives Settings availability (a not-detected
// integration shows a disabled "Not detected" toggle). Refreshed by the Engine on the main actor at
// launch and on a ~30s cadence — the probe is a few `fileExists` checks, cheap enough for the tick.
@MainActor @Observable public final class IntegrationStore {
    public var detected: Set<Integration>
    private let home: URL

    public init(home: URL, detected: Set<Integration> = []) {
        self.home = home
        self.detected = detected
    }

    // Detection is "does the tool's marker directory exist". The marker path is owned by the
    // integration's descriptor, so there is no central switch to keep in step with the registry.
    // Only supported integrations are probed: suspended cases keep their stored settings but are
    // never detected, initialized or shown. Persistence still iterates `allCases` (see SettingsStore).
    public func refresh() {
        let fm = FileManager.default
        let found = Set(
            Integration.supportedCases.filter {
                fm.fileExists(atPath: home.appendingPathComponent($0.descriptor.homeRelativePath).path)
            })
        if found != detected { detected = found }  // only notify observers on an actual change
    }
}
