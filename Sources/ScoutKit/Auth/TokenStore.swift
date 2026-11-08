import Foundation

/// An access token obtained with client credentials. Only the token, its expiry and its app ID are persisted.
public struct CachedToken: Codable, Sendable, Equatable {
    public var appID: String
    public var accessToken: String
    public var expiresAt: Date

    public init(appID: String, accessToken: String, expiresAt: Date) {
        self.appID = appID
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

extension CachedToken: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "CachedToken(appID: \(appID), accessToken: <redacted>, expiresAt: \(expiresAt))" }
    public var debugDescription: String { description }
}

public protocol TokenStore: Sendable {
    func load() async throws -> CachedToken?
    func save(_ token: CachedToken) async throws
    func remove() async throws
}

/// Stores the single cached token as JSON in a private directory (0700) and file (0600).
public struct FileTokenStore: TokenStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/.config/scout/token.json`
    public static func standard(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> FileTokenStore {
        FileTokenStore(fileURL: homeDirectory.appendingPathComponent(".config/scout/token.json"))
    }

    /// A missing or unreadable cache means a new token is requested; saving it reports any file problem.
    public func load() throws -> CachedToken? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.decoder().decode(CachedToken.self, from: data)
    }

    /// Writes a temporary file created with mode 0600, then renames it over the cache atomically.
    public func save(_ token: CachedToken) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw ScoutError.configuration(
                "Could not prepare the token cache directory \(directory.path): \(error.localizedDescription)"
            )
        }
        let data: Data
        do {
            data = try Self.encoder().encode(token)
        } catch {
            throw ScoutError.configuration("Could not encode the token cache.")
        }

        let temporaryPath = directory.appendingPathComponent(".token-\(UUID().uuidString).tmp").path
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Self.failure("create", temporaryPath, errno) }
        var replaced = false
        defer { if !replaced { unlink(temporaryPath) } }

        let writeError = Self.writeAll(data, to: descriptor)
        let closeError = close(descriptor) == 0 ? nil : errno
        if let error = writeError ?? closeError { throw Self.failure("write", temporaryPath, error) }
        guard rename(temporaryPath, fileURL.path) == 0 else { throw Self.failure("replace", fileURL.path, errno) }
        replaced = true
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw ScoutError.configuration(
                "Could not remove the token cache \(fileURL.path): \(error.localizedDescription)"
            )
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Int32? {
        data.withUnsafeBytes { buffer -> Int32? in
            guard let base = buffer.baseAddress else { return nil }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, base + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += count
            }
            return nil
        }
    }

    private static func failure(_ action: String, _ path: String, _ code: Int32) -> ScoutError {
        .configuration("Could not \(action) the token cache file \(path): \(String(cString: strerror(code)))")
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
