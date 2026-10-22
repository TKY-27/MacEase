import Foundation
import MenuCatalog

enum TokenStore {
    private static let defaultsKey = "requestToken"

    static func current(in defaults: UserDefaults = .standard) throws -> String {
        if let token = defaults.string(forKey: defaultsKey), RequestToken.isWellFormed(token) { return token }
        return try rotate(in: defaults)
    }

    @discardableResult
    static func rotate(in defaults: UserDefaults = .standard) throws -> String {
        let token = try RequestToken.generate()
        defaults.set(token, forKey: defaultsKey)
        return token
    }
}
