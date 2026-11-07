import Foundation
import XCTest
@testable import ScoutKit

/// Serves `/start` as a redirect to `/target` without touching the network.
private final class RedirectingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let target = URL(string: "https://api.helpscout.net/target") else { return }
        if url.path == "/start" {
            let headers = ["Location": target.absoluteString, "X-Test": "redirect"]
            guard let response = HTTPURLResponse(url: url, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: headers)
            else { return }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("moved".utf8))
        } else {
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("followed".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class URLSessionTransportTests: XCTestCase {
    func testReturnsRedirectsInsteadOfFollowingThem() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let transport = URLSessionTransport(configuration: configuration)

        let response = try await transport.send(
            HTTPRequest(method: "GET", url: try XCTUnwrap(URL(string: "https://api.helpscout.net/start")))
        )

        XCTAssertEqual(response.statusCode, 301)
        XCTAssertEqual(response.header("location"), "https://api.helpscout.net/target")
        XCTAssertEqual(response.header("x-test"), "redirect")
    }
}
