import Foundation
import XCTest
@testable import ScoutKit

final class FileTokenStoreTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scout-token-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func token(_ value: String) -> CachedToken {
        CachedToken(appID: "app-id", accessToken: value, expiresAt: Date(timeIntervalSince1970: 1_800_172_800))
    }

    func testCreatesPrivateCacheEvenWithPermissiveUmaskAndPersistsAcrossInstances() throws {
        let store = FileTokenStore.standard(homeDirectory: home)
        XCTAssertEqual(store.fileURL.path, home.appendingPathComponent(".config/scout/token.json").path)

        let previousMask = umask(0)
        defer { umask(previousMask) }
        try store.save(token("token-1"))

        let directory = store.fileURL.deletingLastPathComponent()
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(store.fileURL), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["token.json"])

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        XCTAssertEqual(json?.keys.sorted(), ["accessToken", "appID", "expiresAt"])
        XCTAssertEqual(try FileTokenStore(fileURL: store.fileURL).load(), token("token-1"))
    }

    func testReplacementStaysPrivateAndTightensExistingDirectory() throws {
        let store = FileTokenStore.standard(homeDirectory: home)
        let directory = store.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )

        try store.save(token("token-1"))
        try store.save(token("token-2"))

        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(store.fileURL), 0o600)
        XCTAssertEqual(try store.load(), token("token-2"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["token.json"])
    }

    func testCorruptCacheIsIgnoredAndRemoveIsIdempotent() throws {
        let store = FileTokenStore.standard(homeDirectory: home)
        XCTAssertNil(try store.load())
        try store.remove()

        try store.save(token("token-1"))
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertNil(try store.load())

        try store.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        try store.remove()
    }
}
