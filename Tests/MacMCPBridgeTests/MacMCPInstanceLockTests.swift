import Foundation
import XCTest
@testable import MacMCPBridge

final class MacMCPInstanceLockTests: XCTestCase {
    func testLockIsExclusiveAndUsesPrivatePaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("runtime.lock")

        var first: MacMCPInstanceLock? = try XCTUnwrap(MacMCPInstanceLock.acquire(fileURL: lockURL))
        XCTAssertNil(try MacMCPInstanceLock.acquire(fileURL: lockURL))
        withExtendedLifetime(first) {}

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, 0o600)

        first = nil
        XCTAssertNotNil(try MacMCPInstanceLock.acquire(fileURL: lockURL))
    }
}
