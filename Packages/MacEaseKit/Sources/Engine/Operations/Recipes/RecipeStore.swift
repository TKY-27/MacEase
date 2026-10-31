import Foundation

public actor RecipeStore {
    public static let fileName = "recipes.json"
    public static let didChangeNotification = Notification.Name("MacEaseRecipesDidChange")
    private static let schema = 1
    private static let persistenceLock = NSRecursiveLock()
    private let file: URL

    private struct Library: Codable {
        let schema: Int
        let recipes: [Recipe]
    }

    public init(supportDirectory: URL) {
        file = supportDirectory.appending(path: Self.fileName)
    }

    public func recipes() throws -> [Recipe] {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        guard FileManager.default.fileExists(atPath: file.path) else { return Recipe.builtIns }
        let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: file))
        guard library.schema == Self.schema else { throw RecipeError.unsupportedSchema(library.schema) }
        guard Set(library.recipes.map(\.id)).count == library.recipes.count else {
            throw RecipeError.invalidRecipe
        }
        for recipe in library.recipes { try recipe.validate() }
        return library.recipes
    }

    @discardableResult
    public func save(_ recipe: Recipe) throws -> Recipe {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        try recipe.validate()
        var saved = try recipes()
        var revised = recipe
        if let position = saved.firstIndex(where: { $0.id == recipe.id }) {
            guard saved[position].revision < Int.max else { throw RecipeError.invalidRecipe }
            revised.revision = saved[position].revision + 1
            saved[position] = revised
        } else {
            revised.revision = 1
            saved.append(revised)
        }
        try write(saved)
        return revised
    }

    public func delete(_ id: UUID) throws {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        try write(try recipes().filter { $0.id != id })
    }

    @discardableResult
    public func duplicate(_ id: UUID) throws -> Recipe {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        guard var duplicate = try recipes().first(where: { $0.id == id }) else {
            throw RecipeError.invalidRecipe
        }
        duplicate.id = UUID()
        duplicate.name += " Copy"
        return try save(duplicate)
    }

    private func write(_ recipes: [Recipe]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Library(schema: Self.schema, recipes: recipes)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
