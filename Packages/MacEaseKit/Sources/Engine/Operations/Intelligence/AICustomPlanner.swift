import Foundation
import FoundationModels
import MenuCatalog

@Generable
struct GeneratedStep {
    @Guide(description: "An operation identifier copied from the list")
    var operation: String
    @Guide(description: "A preset identifier of that operation, copied from the list")
    var preset: String
}

@Generable
struct GeneratedPlan {
    @Guide(description: "Steps to run in order", .count(1...3))
    var steps: [GeneratedStep]
}

public struct CustomStep: Hashable, Sendable {
    public let operation: OperationID
    public let preset: String
}

/// Menu steps for the Custom panel.
public enum AICustomPlanner {
    public static func plan(_ request: String, kind: FileKind) async throws -> [CustomStep] {
        guard AINaming.isAvailable else { throw EngineError.missingCapability(.appleIntelligence) }
        let session = LanguageModelSession(instructions: Instructions(instructions(for: kind)))
        let generated = try await session.respond(to: request, generating: GeneratedPlan.self).content
        return try generated.steps.map { try validated($0, kind: kind) }
    }

    static func instructions(for kind: FileKind) -> String {
        let catalog = OperationID.allCases
            .filter { $0.kind == kind && !$0.presets.isEmpty }
            .map { "\($0.rawValue): \($0.presets.joined(separator: ", "))" }
            .joined(separator: "\n")
        return """
            Plan file operations for the user's request using only these operations and presets:
            \(catalog)
            """
    }

    /// Rejects steps outside the menu.
    static func validated(_ step: GeneratedStep, kind: FileKind) throws -> CustomStep {
        guard let operation = OperationID(rawValue: step.operation), operation.kind == kind else {
            throw EngineError.invalidInput(.malformed("unknown operation \(step.operation)"))
        }
        guard operation.presets.contains(step.preset) else {
            throw EngineError.invalidInput(.malformed("\(step.preset) is not a preset of \(step.operation)"))
        }
        return CustomStep(operation: operation, preset: step.preset)
    }
}
