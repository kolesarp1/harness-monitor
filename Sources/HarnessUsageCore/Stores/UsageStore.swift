import Foundation
import Observation

// View-facing observable usage snapshots, keyed by integration. Populated by the Engine from each
// monitor's result. An integration absent from the map = no usage (disabled, or has no usage source).
@MainActor @Observable public final class UsageStore {
    public var byIntegration: [Integration: UsageSnapshot] = [:]
    public init(byIntegration: [Integration: UsageSnapshot] = [:]) {
        self.byIntegration = byIntegration
    }
    public subscript(_ integration: Integration) -> UsageSnapshot? {
        get { byIntegration[integration] }
        set { byIntegration[integration] = newValue }
    }
}
