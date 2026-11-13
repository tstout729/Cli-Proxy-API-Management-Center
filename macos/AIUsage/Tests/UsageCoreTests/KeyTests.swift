import Foundation
import XCTest
@testable import UsageCore

final class KeyTests: XCTestCase {
    func testPrivateRegularFileOnlyAndNoSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic-key")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("synthetic-test-only\n".utf8),
                                                     attributes: [.posixPermissions: 0o600]))
        XCTAssertEqual(try ManagementKey.read(path: file.path), "synthetic-test-only")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        XCTAssertThrowsError(try ManagementKey.read(path: file.path)) { error in
            XCTAssertEqual(error as? UsageFailure, .keyPermissions)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let link = directory.appendingPathComponent("synthetic-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ManagementKey.read(path: link.path))
        XCTAssertThrowsError(try ManagementKey.read(path: directory.path))
        XCTAssertThrowsError(try ManagementKey.read(path: directory.appendingPathComponent("missing").path))
    }

    func testMalformedKeyDoesNotExposeContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic-key")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("synthetic\ninvalid".utf8),
                                                     attributes: [.posixPermissions: 0o600]))
        XCTAssertThrowsError(try ManagementKey.read(path: file.path)) { error in
            XCTAssertEqual(error as? UsageFailure, .keyUnavailable)
            XCTAssertFalse((error as? UsageFailure)?.message.contains("synthetic") ?? true)
        }
    }
}
