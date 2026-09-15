import Testing

@testable import HarnessUsageCore

@Test func opusPricingParsesModernMajorVersionsAndDateStamps() {
    #expect(ModelPricing.claudeRate("claude-opus-5-20260501").input == 5)
    #expect(ModelPricing.claudeRate("claude-opus-5-20260501").output == 25)
    #expect(ModelPricing.claudeRate("claude-opus-4-20250514").input == 15)
    #expect(ModelPricing.claudeRate("claude-opus-4-20250514").output == 75)
    #expect(ModelPricing.claudeRate("claude-3-opus-20240229").input == 15)
    #expect(ModelPricing.claudeRate("claude-3-opus-20240229").output == 75)
}
