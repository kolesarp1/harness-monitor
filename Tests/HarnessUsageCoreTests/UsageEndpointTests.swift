import Foundation
import Testing

@testable import HarnessUsageCore

private let now = Date(timeIntervalSince1970: 1_755_600_000)

@Test func retryAfterUsesAOneHourCeiling() throws {
    let huge = try #require(
        HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "999999999"]))
    let short = try #require(
        HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "120"]))

    #expect(UsageEndpoint.retryAfter(from: huge, now: now) == now.addingTimeInterval(3_600))
    #expect(UsageEndpoint.retryAfter(from: short, now: now) == now.addingTimeInterval(120))
}
