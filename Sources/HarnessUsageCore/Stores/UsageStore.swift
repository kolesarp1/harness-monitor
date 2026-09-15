import Foundation
import Observation

// View-facing observable usage snapshots, one per login. Populated by the Engine from each monitor's
// result. A key absent from the map = no usage (disabled, or no usage source).
@MainActor @Observable public final class UsageStore {
    public var readings: [UsageKey: UsageSnapshot] = [:]

    public init(readings: [UsageKey: UsageSnapshot] = [:]) {
        self.readings = readings
    }

    // Each harness's default login — the reading every harness has, and the one provider-level choices
    // (the card's most-drained fallback, the token-estimate prompt, a Settings row's note) are made from.
    public var byIntegration: [Integration: UsageSnapshot] {
        Dictionary(
            uniqueKeysWithValues: readings.compactMap { key, snapshot in
                key.profile == nil ? (key.integration, snapshot) : nil
            })
    }

    public subscript(_ integration: Integration) -> UsageSnapshot? { readings[UsageKey(integration)] }
    public subscript(_ key: UsageKey) -> UsageSnapshot? { readings[key] }

    /// The logins a harness is reporting: the default first, then its profiles by name.
    public func keys(for integration: Integration) -> [UsageKey] {
        readings.keys.filter { $0.integration == integration }
            .sorted { ($0.profile ?? "") < ($1.profile ?? "") }
    }

    /// Whether a harness reports a login beyond its default — the point at which its rings and cards
    /// need a letter and a folder to tell them apart.
    public func hasProfiles(_ integration: Integration) -> Bool {
        readings.keys.contains { $0.integration == integration && $0.profile != nil }
    }
}
