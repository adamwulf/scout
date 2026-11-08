import Foundation
import XCTest
@testable import ScoutKit

final class InlineImageTests: XCTestCase {
    static let canaryImage = "https://d33v4339jhl8k0.cloudfront.net/inline/192496/1f31ca5ad8c98566bedbec21074629654556ee6f/152a0f03e9dfc166b36037801ae72fba52a3ec73/6ED8F9BB-BF20-4EF1-930F-E829E7355D47_4_5005_c.jpeg"
    static let appleMailImage = "https://d33v4339jhl8k0.cloudfront.net/inline/192496/0474d335ec328b4b649314f4f8e3f809a23816f2/d8d74fedc4323b392fc378a8253824c5272a0715/CleanShot-2026-10-15-at-14-09-13-2x.png"

    func testRecognizesHelpScoutInlineImagesAndUsesTheDecodedURLFileName() throws {
        XCTAssertEqual(InlineImage(source: Self.canaryImage)?.filename, "6ED8F9BB-BF20-4EF1-930F-E829E7355D47_4_5005_c.jpeg")
        XCTAssertEqual(InlineImage(source: Self.appleMailImage)?.filename, "CleanShot-2026-10-15-at-14-09-13-2x.png")
        let encoded = try XCTUnwrap(InlineImage(source: "https://D33V4339JHL8K0.cloudfront.NET:443/inline/1/abc/Screen%20Shot%20(1).png"))
        XCTAssertEqual(encoded.filename, "Screen Shot (1).png")
        XCTAssertEqual(encoded.source, "https://D33V4339JHL8K0.cloudfront.NET:443/inline/1/abc/Screen%20Shot%20(1).png")
        XCTAssertEqual(InlineImage(source: "https://d33v4339jhl8k0.cloudfront.net/inline/a.png?v=2")?.filename, "a.png")
    }

    func testRejectsLookalikeAndNonInlineURLs() {
        let rejected = [
            "https://d33v4339jhl8k0.cloudfront.net.evil.com/inline/192496/a/b/photo.png",
            "https://evil.com/inline/192496/a/b/photo.png",
            "https://xd33v4339jhl8k0.cloudfront.net/inline/a.png",
            "http://d33v4339jhl8k0.cloudfront.net/inline/192496/a/b/photo.png",
            "HTTPS://d33v4339jhl8k0.cloudfront.net/inline/a.png",
            "https://d33v4339jhl8k0.cloudfront.net/customer-avatar/192496/a.png",
            "https://d33v4339jhl8k0.cloudfront.net/inline",
            "https://d33v4339jhl8k0.cloudfront.net/inline/",
            "https://d33v4339jhl8k0.cloudfront.net/Inline/a.png",
            "https://d33v4339jhl8k0.cloudfront.net/inlined/a.png",
            "https://d33v4339jhl8k0.cloudfront.net//inline/a.png",
            "https://d33v4339jhl8k0.cloudfront.net/inline//a.png",
            "https://d33v4339jhl8k0.cloudfront.net/inline/../customer-avatar/a.png",
            "https://d33v4339jhl8k0.cloudfront.net/inline/%2E%2E/customer-avatar/a.png",
            "https://d33v4339jhl8k0.cloudfront.net/inline/a%2F..%2Fb.png",
            "https://d33v4339jhl8k0.cloudfront.net:8443/inline/a.png",
            "https://user@d33v4339jhl8k0.cloudfront.net/inline/a.png",
            "https://user:pass@d33v4339jhl8k0.cloudfront.net/inline/a.png",
            "//d33v4339jhl8k0.cloudfront.net/inline/a.png",
            "data:image/png;base64,AAAA",
            "cid:image001.png@01D9",
            "inline/a.png",
            "",
        ]
        for source in rejected {
            XCTAssertNil(InlineImage(source: source), source)
            if let url = URL(string: source) { XCTAssertFalse(InlineImage.isHelpScoutInlineImage(url), source) }
        }
    }

    // MARK: CDN fetch

    private func http(_ configuration: ScoutConfiguration, _ replies: [ScriptedHTTPTransport.Reply]) -> (ScoutHTTPClient, ScriptedHTTPTransport) {
        let transport = ScriptedHTTPTransport(replies)
        return (ScoutHTTPClient(configuration: configuration, transport: transport, tokenStore: InMemoryTokenStore()), transport)
    }

    private let configurations: [ScoutConfiguration] = [
        .init(accessToken: "secret-token"),
        .init(appID: "app-id", appSecret: "app-secret"),
    ]

    func testFetchSendsOnePlainGETWithoutCredentials() async throws {
        let url = try XCTUnwrap(URL(string: Self.canaryImage))
        for configuration in configurations {
            let (client, transport) = http(configuration, [.response(HTTPResponse(statusCode: 200, body: Data("jpeg".utf8)))])

            let data = try await client.inlineImageData(url)

            XCTAssertEqual(data, Data("jpeg".utf8))
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1, "No token exchange or retry")
            XCTAssertEqual(requests.first?.method, "GET")
            XCTAssertEqual(requests.first?.url, url)
            XCTAssertNil(requests.first?.body)
            XCTAssertEqual(requests.first?.headers, ["Accept": "image/*"])
            XCTAssertNil(requests.first?.headers.first { $0.key.lowercased() == "authorization" })
        }
    }

    func testFetchRejectsNonInlineURLsBeforeAnyRequest() async throws {
        for source in ["https://d33v4339jhl8k0.cloudfront.net.evil.com/inline/a.png", "http://d33v4339jhl8k0.cloudfront.net/inline/a.png",
                       "https://d33v4339jhl8k0.cloudfront.net/customer-avatar/a.png", "https://api.helpscout.net/v2/users/me"] {
            let (client, transport) = http(configurations[0], [.json(200, "x")])
            do {
                _ = try await client.inlineImageData(try XCTUnwrap(URL(string: source)))
                XCTFail("Fetched \(source)")
            } catch ScoutError.invalidInput(let message) {
                XCTAssertTrue(message.hasPrefix("Scout only downloads inline images from Help Scout's image CDN"), message)
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 0, source)
        }
    }

    func testFetchFailuresAreNotRetried() async throws {
        let url = try XCTUnwrap(URL(string: Self.appleMailImage))
        let cases: [(ScriptedHTTPTransport.Reply, ScoutError)] = [
            (.json(302, "", headers: ["Location": "https://evil.com/x.png"]),
             .api(status: 302, message: "Help Scout's image CDN returned a redirect that Scout does not follow.")),
            (.json(404, "<Error/>"), .api(status: 404, message: "Help Scout's image CDN did not return the image.")),
            (.json(200, ""), .decoding("Help Scout's image CDN returned an empty file.")),
        ]
        for (reply, expected) in cases {
            let (client, transport) = http(configurations[0], [reply, .json(200, "again")])
            do {
                _ = try await client.inlineImageData(url)
                XCTFail("Accepted \(expected)")
            } catch let error as ScoutError {
                XCTAssertEqual(error, expected)
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }

        let (client, transport) = http(configurations[0], [.failure(URLError(.timedOut)), .json(200, "again")])
        do {
            _ = try await client.inlineImageData(url)
            XCTFail("Accepted a transport failure")
        } catch ScoutError.transport(let message) {
            XCTAssertTrue(message.hasPrefix("Network request failed for an inline image on Help Scout's image CDN"), message)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }
}
