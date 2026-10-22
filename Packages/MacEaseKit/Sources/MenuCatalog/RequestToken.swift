import Foundation
import Security

public enum RequestToken {
    public static let byteCount = 32

    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return bytes.hexEncoded
    }

    public static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == byteCount * 2 && token.allSatisfy(\.isHexDigit)
    }

    /// Constant time, so timing reveals nothing.
    public static func matches(_ candidate: String, _ expected: String) -> Bool {
        let lhs = Array(candidate.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension Sequence<UInt8> {
    public var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
