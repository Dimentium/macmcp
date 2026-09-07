import Foundation
import XCTest
@testable import MacMCPBridge

final class MacMCPPathsTests: XCTestCase {
    func testCanonicalPathsUseMacMCPNamespace() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        XCTAssertEqual(
            MacMCPPaths.applicationSupportDirectory(homeDirectory: home).path,
            "/Users/test/Library/Application Support/macmcp"
        )
        XCTAssertEqual(
            MacMCPPaths.runtimeCacheDirectory(homeDirectory: home).path,
            "/Users/test/Library/Caches/macmcp"
        )
    }

    func testLegacyPathIsKeptOnlyForMigration() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        XCTAssertEqual(
            MacMCPPaths.legacyApplicationSupportFile("launch.json", homeDirectory: home).path,
            "/Users/test/Library/Application Support/mac-agent-bridge/launch.json"
        )
    }
}
