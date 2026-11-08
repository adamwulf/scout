import Foundation

extension ScoutHTTPClient {
    /// Fetches a Help Scout inline image from its CDN through the injected transport. The URL is checked again here,
    /// so nothing but a Help Scout inline image URL is ever requested. The request carries no `Authorization` header,
    /// because the CDN needs no credentials and must never receive the API token. Nothing is retried; the transport
    /// refuses redirects, so a 3xx is a failure, as are other non-2xx responses and an empty body.
    func inlineImageData(_ url: URL) async throws -> Data {
        guard InlineImage.isHelpScoutInlineImage(url) else {
            throw ScoutError.invalidInput("Scout only downloads inline images from Help Scout's image CDN (https://\(InlineImage.host)/inline/).")
        }
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(method: "GET", url: url, headers: ["Accept": "image/*"]))
        } catch {
            throw ScoutError.transport(redactor.redact("Network request failed for an inline image on Help Scout's image CDN: \(error.localizedDescription)"))
        }
        switch response.statusCode {
        case 200..<300:
            guard !response.body.isEmpty else { throw ScoutError.decoding("Help Scout's image CDN returned an empty file.") }
            return response.body
        case 300..<400:
            throw ScoutError.api(status: response.statusCode, message: "Help Scout's image CDN returned a redirect that Scout does not follow.")
        default:
            throw ScoutError.api(status: response.statusCode, message: "Help Scout's image CDN did not return the image.")
        }
    }
}
