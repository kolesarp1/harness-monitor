import Foundation
import Testing

@testable import HarnessUsageCore

@Suite struct CodexPlanMetadataTests {
    // Defect: the usage decoder dropping `plan_type`, leaving an old JWT claim in place even after a
    // successful provider response reports richer current metadata.
    @Test func successfulUsagePreservesCurrentAndUnfamiliarProviderPlanNames() throws {
        let reset = Int(Date(timeIntervalSince1970: 2_000).timeIntervalSince1970)
        let data = Data(
            """
            {"account_id":"workspace-1","email":"person@example.com","plan_type":"future_plan_7x",
             "rate_limit":{"primary_window":{"used_percent":42,"reset_at":\(reset),"limit_window_seconds":3600}}}
            """.utf8)
        let snapshot = try #require(
            CodexUsageClient.snapshot(fromResponseData: data, now: Date(timeIntervalSince1970: 1_000)))
        #expect(snapshot.account?.id == "workspace-1")
        #expect(snapshot.account?.plan == "Future_plan_7x")
        #expect(snapshot.account?.email == "person@example.com")
    }

    @Test func successfulUsageUsesTheSameKnownPlanDisplayPolicyAsPresentation() throws {
        let data = Data(
            """
            {"account_id":"workspace-1","plan_type":"ProLite",
             "rate_limit":{"primary_window":{"used_percent":42,"reset_at":2000,"limit_window_seconds":3600}}}
            """.utf8)
        let snapshot = try #require(
            CodexUsageClient.snapshot(fromResponseData: data, now: Date(timeIntervalSince1970: 1_000)))
        #expect(snapshot.account?.plan == "Pro Lite")
        #expect(snapshot.account?.plan == Integration.codex.planDisplayName("Prolite"))
    }
}
