import Foundation

/// An image pasted into a message body, which Help Scout rewrites to its own CDN. Such images are not in a thread's
/// attachment list; they exist only as `<img>` tags in the thread's HTML body and download without credentials.
struct InlineImage: Hashable, Sendable {
    static let host = "d33v4339jhl8k0.cloudfront.net"

    /// The `src` as written in the body, entity-decoded and trimmed. Downloads are deduplicated and looked up by it.
    let source: String
    let url: URL
    /// The URL's last path segment, percent-decoded. Never the `alt` text, which is sometimes the URL itself.
    let filename: String

    /// Nil unless `source` is a Help Scout inline image URL; see `isHelpScoutInlineImage(_:)`.
    init?(source: String) {
        guard let url = URL(string: source), Self.isHelpScoutInlineImage(url),
            let last = url.path(percentEncoded: true).split(separator: "/").last
        else { return nil }
        self.source = source
        self.url = url
        filename = Self.decoded(last)
    }

    /// True for an `https` URL on exactly the CDN host (any case) with the default port and no user info, whose
    /// path is `/inline/` followed by one or more nonempty segments. Dot segments and segments that decode to a
    /// path separator are rejected, so the request cannot resolve to another CDN path such as `/customer-avatar/`.
    static func isHelpScoutInlineImage(_ url: URL) -> Bool {
        let segments = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false)
        return url.scheme == "https"
            && url.host(percentEncoded: true)?.lowercased() == host
            && (url.port == nil || url.port == 443)
            && url.user() == nil && url.password() == nil
            && segments.count >= 3 && segments[0].isEmpty && segments[1] == "inline"
            && segments.dropFirst(2).allSatisfy { segment in
                let text = decoded(segment)
                return !text.isEmpty && text != "." && text != ".." && !text.contains("/") && !text.contains("\\")
            }
    }

    private static func decoded(_ segment: Substring) -> String {
        String(segment).removingPercentEncoding ?? String(segment)
    }
}
