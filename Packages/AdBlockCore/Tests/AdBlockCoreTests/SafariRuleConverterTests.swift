import XCTest
@testable import AdBlockCore

final class SafariRuleConverterTests: XCTestCase {
    func testDomainAnchorRule() throws {
        let rule = try XCTUnwrap(SafariRuleConverter.networkRule(from: "||doubleclick.net^"))
        XCTAssertEqual(rule.action.type, .block)
        XCTAssertEqual(rule.trigger.urlFilter, "^[^:]+://+([^/:]+\\.)?doubleclick\\.net[/:]")
        try assertRegex(rule.trigger.urlFilter, matches: "https://ad.doubleclick.net/foo")
        try assertRegex(rule.trigger.urlFilter, matches: "https://doubleclick.net/")
        try assertRegex(rule.trigger.urlFilter, doesNotMatch: "https://notdoubleclick.net/")
        try assertRegex(rule.trigger.urlFilter, doesNotMatch: "https://doubleclick.network/")
    }

    func testOptions() throws {
        let rule = try XCTUnwrap(SafariRuleConverter.networkRule(from: "||ads.example.com^$script,third-party,domain=a.com|b.com"))
        XCTAssertEqual(rule.trigger.resourceType, ["script"])
        XCTAssertEqual(rule.trigger.loadType, ["third-party"])
        XCTAssertEqual(rule.trigger.ifDomain, ["*a.com", "*b.com"])
        XCTAssertNil(rule.trigger.unlessDomain)
    }

    func testNegatedDomainsBecomeUnlessDomain() throws {
        let rule = try XCTUnwrap(SafariRuleConverter.networkRule(from: "/banner/*$domain=~example.com"))
        XCTAssertEqual(rule.trigger.unlessDomain, ["*example.com"])
        XCTAssertEqual(rule.trigger.urlFilter, "/banner/")
    }

    func testWildcardAndSeparator() throws {
        let rule = try XCTUnwrap(SafariRuleConverter.networkRule(from: "/ads/*.gif^"))
        XCTAssertEqual(rule.trigger.urlFilter, "/ads/.*\\.gif")
        let middle = try XCTUnwrap(SafariRuleConverter.networkRule(from: "&ad_type=^foo"))
        XCTAssertEqual(middle.trigger.urlFilter, "&ad_type=[/:?&=]foo")
    }

    func testExceptionRule() throws {
        let rule = try XCTUnwrap(SafariRuleConverter.networkRule(from: "@@||example.com/ads.js"))
        XCTAssertEqual(rule.action.type, .ignorePreviousRules)
    }

    func testDocumentExceptionAllowlistsSite() throws {
        let rule = try XCTUnwrap(SafariRuleConverter.networkRule(from: "@@||example.org^$document"))
        XCTAssertEqual(rule, ContentBlockerRule.allowlist(domain: "example.org"))
    }

    func testUnsupportedRulesAreSkipped() {
        XCTAssertNil(SafariRuleConverter.networkRule(from: "||example.com^$redirect=noopjs"))
        XCTAssertNil(SafariRuleConverter.networkRule(from: "||example.com^$csp=script-src 'none'"))
        XCTAssertNil(SafariRuleConverter.networkRule(from: "/^https?:\\/\\/ads/"))
        XCTAssertNil(SafariRuleConverter.networkRule(from: "*"))
        XCTAssertNil(SafariRuleConverter.networkRule(from: "ad"))
    }

    func testFullConversionOrdersRulesCorrectly() throws {
        let list = """
        [Adblock Plus 2.0]
        ! Title: Test
        ||ads.example.com^
        @@||ads.example.com/allowed^
        ##.ad-banner
        ##.sponsored
        example.com##.local-ad
        example.com#@#.ad-banner
        example.com#?#div:has-text(Sponsored)
        example.com##+js(abort-on-property-read, foo)
        """
        let result = SafariRuleConverter().convert(filterLists: [list], allowlistedDomains: ["mysite.it"])

        XCTAssertEqual(result.skippedFilters, 2)
        XCTAssertFalse(result.truncated)

        let types = result.rules.map(\.action.type)
        XCTAssertEqual(types, [.cssDisplayNone, .cssDisplayNone, .cssDisplayNone, .block, .ignorePreviousRules, .ignorePreviousRules])

        // .ad-banner is disabled on example.com, .sponsored is not.
        let generic = result.rules.filter { $0.trigger.ifDomain == nil && $0.action.type == .cssDisplayNone }
        XCTAssertTrue(generic.contains { $0.action.selector == ".ad-banner" && $0.trigger.unlessDomain == ["*example.com"] })
        XCTAssertTrue(generic.contains { $0.action.selector == ".sponsored" && $0.trigger.unlessDomain == nil })

        XCTAssertEqual(result.rules.last, ContentBlockerRule.allowlist(domain: "mysite.it"))

        let json = try result.rules.contentBlockerJSON()
        let decoded = try JSONSerialization.jsonObject(with: json) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, result.rules.count)
        let firstTrigger = decoded?.first?["trigger"] as? [String: Any]
        XCTAssertEqual(firstTrigger?["url-filter"] as? String, ".*")
    }

    func testRuleLimitKeepsExceptions() {
        let blocks = (0..<50).map { "||ads\($0).example.com^" }.joined(separator: "\n")
        let list = blocks + "\n@@||ads1.example.com^\n##.ad"
        let result = SafariRuleConverter(maxRules: 10).convert(filterLists: [list], allowlistedDomains: ["a.com"])
        XCTAssertEqual(result.rules.count, 10)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.rules.filter { $0.action.type == .ignorePreviousRules }.count, 2)
    }

    func testSelectorsAreGrouped() {
        let list = (0..<100).map { "##.ad-\($0)" }.joined(separator: "\n")
        let result = SafariRuleConverter(selectorsPerRule: 40).convert(filterLists: [list])
        XCTAssertEqual(result.rules.count, 3)
    }

    // MARK: Helpers

    private func assertRegex(_ pattern: String, matches url: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let regex = try NSRegularExpression(pattern: pattern)
        XCTAssertNotNil(regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)), "\(pattern) should match \(url)", file: file, line: line)
    }

    private func assertRegex(_ pattern: String, doesNotMatch url: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let regex = try NSRegularExpression(pattern: pattern)
        XCTAssertNil(regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)), "\(pattern) should not match \(url)", file: file, line: line)
    }
}
