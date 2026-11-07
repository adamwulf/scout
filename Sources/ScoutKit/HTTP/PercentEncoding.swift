import Foundation

/// Strict percent encoding for query strings and form bodies. Only RFC 3986 unreserved characters stay literal,
/// so `+` becomes `%2B` and can never be read back as a space.
enum PercentEncoding {
    static func encode(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            if isUnreserved(byte) {
                encoded.append(Character(Unicode.Scalar(byte)))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    static func form(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
            UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }
}
