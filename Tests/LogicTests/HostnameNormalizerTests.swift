import XCTest
@testable import StatsCore

final class HostnameNormalizerTests: XCTestCase {
    func testLowercasesHostname() {
        XCTAssertEqual(HostnameNormalizer.normalize("WWW.Example.COM"), "www.example.com")
    }

    func testStripsTrailingDots() {
        XCTAssertEqual(HostnameNormalizer.normalize("example.com."), "example.com")
        XCTAssertEqual(HostnameNormalizer.normalize("example.com.."), "example.com")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(HostnameNormalizer.normalize("  example.com\n"), "example.com")
    }

    func testKeepsFullSubdomains() {
        XCTAssertEqual(HostnameNormalizer.normalize("a.b.c.example.com"), "a.b.c.example.com")
    }

    func testAlreadyNormalizedStaysUnchanged() {
        XCTAssertEqual(HostnameNormalizer.normalize("example.com"), "example.com")
    }

    func testRejectsEmptyAndDotsOnly() {
        XCTAssertNil(HostnameNormalizer.normalize(""))
        XCTAssertNil(HostnameNormalizer.normalize("   "))
        XCTAssertNil(HostnameNormalizer.normalize("..."))
    }
}
