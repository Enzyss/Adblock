#if os(macOS) && canImport(WebKit)
import AdBlockCore
import WebKit
import XCTest

/// End-to-end check: downloads the real filter lists, converts them and asks
/// WebKit (the same engine Safari uses) to compile the result.
///
/// Needs network access, so it only runs with `ADBLOCK_LIVE_TESTS=1`.
@MainActor
final class LiveFilterListTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ADBLOCK_LIVE_TESTS"] == "1", "Set ADBLOCK_LIVE_TESTS=1 to run")
    }

    func testSafariCategoriesCompileInWebKit() async throws {
        for category in FilterCategory.safariCategories {
            var texts: [String] = []
            for source in FilterCatalog.lists(in: category) {
                let (data, _) = try await URLSession.shared.data(from: source.url)
                texts.append(String(decoding: data, as: UTF8.self))
            }
            let result = SafariRuleConverter().convert(filterLists: texts, allowlistedDomains: ["example.com"])
            print("\(category.rawValue): \(result.rules.count) rules, \(result.skippedFilters) skipped, truncated: \(result.truncated)")
            XCTAssertGreaterThan(result.rules.count, 1_000)
            XCTAssertLessThanOrEqual(result.rules.count, SafariRuleConverter.safariRuleLimit)

            let json = String(decoding: try result.rules.contentBlockerJSON(), as: UTF8.self)
            let store = try XCTUnwrap(WKContentRuleListStore.default())
            let identifier = "adblock-test-\(category.rawValue)"
            let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
            XCTAssertNotNil(list, "WebKit refused the \(category.rawValue) rules")
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    func testDNSListsParse() async throws {
        var builder = DomainBlocklistBuilder()
        for source in FilterCatalog.lists(in: .dns) {
            let (data, _) = try await URLSession.shared.data(from: source.url)
            builder.add(listText: String(decoding: data, as: UTF8.self))
        }
        let list = builder.build()
        print("dns: \(list.count) domains")
        XCTAssertGreaterThan(list.count, 10_000)
        XCTAssertTrue(list.isBlocked("doubleclick.net"))
        XCTAssertTrue(list.isBlocked("pagead2.googlesyndication.com"))
        XCTAssertFalse(list.isBlocked("apple.com"))
        XCTAssertFalse(list.isBlocked("www.google.com"))
    }
}
#endif
