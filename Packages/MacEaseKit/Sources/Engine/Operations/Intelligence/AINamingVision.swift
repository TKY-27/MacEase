#if compiler(>=6.4)
    import CoreGraphics
    import FoundationModels

    /// macOS 27 models read the picture itself.
    @available(macOS 27, *)
    enum AINamingVision {
        static func name(of picture: CGImage, facts: String, session: LanguageModelSession) async throws -> String {
            let response = try await session.respond(generating: SuggestedName.self) {
                Attachment(picture)
                facts
            }
            return response.content.name
        }
    }
#endif
