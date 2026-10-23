import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct StreamingTextTests {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacEaseStreaming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func encoded(_ text: String, source: SourceTextEncoding) throws -> Data {
        let body = try #require(text.data(using: source.foundation))
        switch source {
        case .utf16LittleEndian: return Data([0xFF, 0xFE]) + body
        case .utf16BigEndian: return Data([0xFE, 0xFF]) + body
        default: return body
        }
    }

    @Test(arguments: SourceTextEncoding.allCases)
    func transcodingMatchesWholeTextAcrossMultibyteBoundaries(_ source: SourceTextEncoding) throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let input = directory.appending(path: "input.txt")
        var settings = TextSettings()
        settings.unmappable = .numericReference
        let unicode = source == .utf8 || source == .utf16LittleEndian || source == .utf16BigEndian
        for offset in 0..<6 {
            let text =
                String(repeating: "a", count: StreamingText.chunkBytes - 3 + offset)
                + (unicode ? "😀e\u{301}\r\n日本語\r末尾" : "日本語\r\n末尾")
            let original = try encoded(text, source: source)
            try original.write(to: input)
            for target in TextEncodingTarget.allCases {
                let output = directory.appending(path: "output-\(offset)-\(target.rawValue).txt")
                let expected = try TextEncoding.encode(
                    text, as: target, unmappable: settings.unmappable, substitute: settings.shiftJISSubstitute)
                let result = try StreamingText.transcode(
                    input, to: output, target: target, source: source, settings: settings)
                #expect(try Data(contentsOf: output) == expected.data, "Offset \(offset), target \(target)")
                #expect(result.encoding == expected.encoding)
                #expect(result.replaced == expected.replaced)
                try StreamingText.validate(output, encoding: result.encoding)
            }
            #expect(try Data(contentsOf: input) == original)
        }
    }

    @Test(arguments: SourceTextEncoding.allCases)
    func lineEndingsPreserveEncodingAndSplitCRLF(_ source: SourceTextEncoding) throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let input = directory.appending(path: "input.txt")
        for offset in 0..<6 {
            let padding = String(repeating: "a", count: StreamingText.chunkBytes - 2 + offset)
            let text = padding + "\r\n日本語\r末尾\n"
            let original = try encoded(text, source: source)
            try original.write(to: input)
            for ending in LineEnding.allCases {
                let output = directory.appending(path: "output-\(offset)-\(ending.rawValue).txt")
                let normalized = ending == .crlf ? "\r\n" : "\n"
                let expectedText = padding + normalized + "日本語" + normalized + "末尾" + normalized
                let expected = try encoded(expectedText, source: source)
                let result = try StreamingText.normalize(input, to: output, ending: ending)
                #expect(try Data(contentsOf: output) == expected)
                #expect(result == source.foundation)
            }
            #expect(try Data(contentsOf: input) == original)
        }
    }

    @Test func byteOrderMarksOverrideChosenEncodingAndSurviveNormalization() throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let input = directory.appending(path: "input.txt")
        let converted = directory.appending(path: "converted.txt")
        let normalized = directory.appending(path: "normalized.txt")
        try Data([0xEF, 0xBB, 0xBF] + Array("日本\r\n語\r".utf8)).write(to: input)
        _ = try StreamingText.transcode(input, to: converted, target: .utf8, source: .eucJP, settings: TextSettings())
        _ = try StreamingText.normalize(input, to: normalized, ending: .lf)
        #expect(try Data(contentsOf: converted) == Data("日本\r\n語\r".utf8))
        #expect(try Data(contentsOf: normalized) == Data([0xEF, 0xBB, 0xBF] + Array("日本\n語\n".utf8)))
        #expect(try StreamingText.equalContents(input, converted) == false)
        #expect(try StreamingText.equalContents(input, input))
    }

    @Test(arguments: [false, true])
    func transcodingPreservesInteriorByteOrderMarksAcrossChunks(_ withHeader: Bool) throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let input = directory.appending(path: "input.txt")
        let output = directory.appending(path: "output.txt")
        let header = withHeader ? Data([0xEF, 0xBB, 0xBF]) : Data()
        for offset in -2...2 {
            let text = String(repeating: "a", count: 65_536 + offset) + "\u{FEFF}b"
            let original = header + Data(text.utf8)
            try original.write(to: input)
            _ = try StreamingText.transcode(input, to: output, target: .utf8, source: nil, settings: TextSettings())
            #expect(try Data(contentsOf: output) == Data(text.utf8), "Offset \(offset), header \(withHeader)")
            #expect(try Data(contentsOf: input) == original)
            try FileManager.default.removeItem(at: output)
        }
    }

    @Test func ambiguousLegacyInputStillRequiresAChoice() throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let input = directory.appending(path: "input.txt")
        let ambiguous = Data([0xA4, 0xA2])
        try ambiguous.write(to: input)
        #expect(throws: EngineError.invalidInput(.textEncodingUndetected)) {
            _ = try StreamingText.transcode(
                input, to: directory.appending(path: "refused.txt"), target: .utf8, source: nil,
                settings: TextSettings())
        }
        let output = directory.appending(path: "chosen.txt")
        _ = try StreamingText.transcode(input, to: output, target: .utf8, source: .eucJP, settings: TextSettings())
        #expect(try Data(contentsOf: output) == Data("あ".utf8))
    }

    @Test func unmappableGraphemeKeepsItsPolicyAndLineAcrossChunks() throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let input = directory.appending(path: "input.txt")
        let padding = String(repeating: "a", count: StreamingText.chunkBytes - 2)
        try Data((padding + "\r\n😀").utf8).write(to: input)
        #expect(throws: EngineError.invalidInput(.unmappableCharacter(line: 2))) {
            _ = try StreamingText.transcode(
                input, to: directory.appending(path: "refused.txt"), target: .shiftJIS, source: nil,
                settings: TextSettings())
        }
        for policy in [UnmappablePolicy.questionMark, .numericReference, .custom] {
            var settings = TextSettings()
            settings.unmappable = policy
            settings.shiftJISSubstitute = "※"
            let output = directory.appending(path: "\(policy.rawValue).txt")
            let expected = try TextEncoding.encode(
                padding + "\r\n😀", as: .shiftJIS, unmappable: policy, substitute: settings.shiftJISSubstitute)
            let result = try StreamingText.transcode(
                input, to: output, target: .shiftJIS, source: nil, settings: settings)
            #expect(result.replaced)
            #expect(try Data(contentsOf: output) == expected.data)
        }
    }

    @Test(arguments: [
        (SourceTextEncoding.utf8, [UInt8(0xF0), 0x9F, 0x98]),
        (.utf16LittleEndian, [0x00, 0xD8]),
        (.utf16BigEndian, [0xD8, 0x00]),
        (.cp932, [0x82]),
        (.eucJP, [0x8F, 0xA1]),
    ])
    func incompleteFinalCharactersFail(_ source: SourceTextEncoding, _ suffix: [UInt8]) throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let input = directory.appending(path: "input.txt")
        let prefix = try encoded(String(repeating: "a", count: StreamingText.chunkBytes), source: source)
        try (prefix + Data(suffix)).write(to: input)
        #expect(throws: EngineError.invalidInput(.textEncodingUndetected)) {
            _ = try StreamingText.transcode(
                input, to: directory.appending(path: "refused.txt"), target: .utf8, source: source,
                settings: TextSettings())
        }
        #expect(try Data(contentsOf: input) == prefix + Data(suffix))
    }

    @Test func cancellationStopsBeforeCreatingOutput() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let input = directory.appending(path: "input.txt")
        let output = directory.appending(path: "output.txt")
        try Data("hello".utf8).write(to: input)
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) {
                _ = try StreamingText.transcode(
                    input, to: output, target: .utf16, source: nil, settings: TextSettings())
            }
        }.value
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
    @Test func plannerStagesAndVerifiesTextWithoutChangingTheOriginal() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let input = directory.appending(path: "input.json")
        let original = Data("{\"key\":1}\n".utf8)
        try original.write(to: input)
        let support = directory.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        for (operation, op, expected) in [
            (
                TextOperation.encoding(.utf16, source: nil), OperationID.textEncoding,
                Data([0xFF, 0xFE]) + (try #require("{\"key\":1}\n".data(using: .utf16LittleEndian)))
            ),
            (.lineEndings(.crlf), .textLineEndings, Data("{\"key\":1}\r\n".utf8)),
            (.json(.pretty), .textJSON, Data("{\n  \"key\": 1\n}\n".utf8)),
            (.encoding(.utf8, source: nil), .textEncoding, original),
        ] {
            let context = ItemContext(settings: Settings(), staging: StagingArea(supportDirectory: support)) { _ in }
            defer { context.removeStaging() }
            let batch = TextPlanner.batch(operation, op: op, inputs: [input])
            let work = try #require(batch.items.first)
            let result = try await work.body(context)
            if expected == original {
                guard case .skipped(.alreadyDone) = result else {
                    Issue.record("Unchanged text was not skipped")
                    continue
                }
            } else {
                guard case .replace(let source, let staged) = result else {
                    Issue.record("Text was not staged for replacement")
                    continue
                }
                #expect(source == input)
                #expect(try Data(contentsOf: staged.url) == expected)
                try await OutputVerifier.verify(staged)
            }
            #expect(try Data(contentsOf: input) == original)
        }
    }

    @Test func outputVerificationRejectsIncompleteMultibyteText() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let output = directory.appending(path: "invalid.txt")
        try Data([0x61, 0xF0, 0x9F]).write(to: output)
        let staged = StagedFile(url: output, name: output.lastPathComponent, check: .text(.utf8))
        await #expect(throws: EngineError.encodeFailed("output text is not valid in its encoding")) {
            try await OutputVerifier.verify(staged)
        }
    }

    @Test(arguments: ["", "b"])
    func oversizedGraphemesFailWithoutChangingTheOriginal(_ suffix: String) throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let input = directory.appending(path: "input.txt")
        let combiningMark = "\u{301}"
        let text = "a" + String(repeating: combiningMark, count: StreamingText.maximumGraphemeBytes / 2) + suffix
        let original = Data(text.utf8)
        try original.write(to: input)
        #expect(throws: EngineError.invalidInput(.malformed("A text character exceeds 1 MiB"))) {
            _ = try StreamingText.transcode(
                input, to: directory.appending(path: "refused.txt"), target: .shiftJIS, source: nil,
                settings: TextSettings())
        }
        #expect(try Data(contentsOf: input) == original)
    }

}
