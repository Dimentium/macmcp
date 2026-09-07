import XCTest
@testable import MacMCPBridge

final class LocalUserPathsTests: XCTestCase {
    func testUsesAbsoluteHomeFromEnvironment() {
        XCTAssertEqual(
            LocalUserPaths.homeDirectoryURL(environment: ["HOME": "/Users/test"]).path,
            "/Users/test"
        )
    }

    func testRejectsRelativeOrControlCharacterHome() {
        XCTAssertEqual(
            LocalUserPaths.homeDirectoryURL(environment: ["HOME": "relative"]).path,
            LocalUserPaths.homeDirectoryURL().path
        )
        XCTAssertEqual(
            LocalUserPaths.homeDirectoryURL(environment: ["HOME": "/Users/test\nunsafe"]).path,
            LocalUserPaths.homeDirectoryURL().path
        )
    }
}
