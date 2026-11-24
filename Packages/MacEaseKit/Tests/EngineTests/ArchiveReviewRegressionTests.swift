import CArchive
import Darwin
import Formats
import Foundation
import Synchronization
import Testing

@testable import Engine

extension ArchiveExtractionRoutingTests {
    private func reviewFixture(_ variant: String, in root: URL, format: String = "zip", comment: Int = 0) throws -> URL
    {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "bundle.\(format)")
        let script = try #require(
            Bundle.module.url(forResource: "review-archive-fixtures", withExtension: "py", subdirectory: "Resources"))
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = [script.path, source.path, variant, String(comment)]
        try python.run()
        python.waitUntilExit()
        try #require(python.terminationStatus == 0)
        return source
    }

    private func reviewDestination(in root: URL, name: String) throws -> URL {
        let destination = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let resolved = try #require(realpath(destination.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    @Test(arguments: ["APFS", "Case-sensitive APFS"])
    func collisionsFollowTheActualDestinationVolume(_ filesystem: String) async throws {
        let volume = try TestDiskImage(filesystem: filesystem)
        let caseSensitive = try #require(
            volume.mount.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames as Bool?)
        #expect(caseSensitive == (filesystem == "Case-sensitive APFS"))
        for format in ["zip", "tar"] {
            for variant in ["duplicate-cp932", "mixed-names", "case", "directory-case", "normalization"] {
                let root = volume.mount.appending(path: UUID().uuidString)
                let source = try reviewFixture(variant, in: root, format: format)
                let original = try Data(contentsOf: source)
                let (outcome, _, _, _) = try await run(source, in: root)
                if caseSensitive && ["case", "directory-case"].contains(variant) {
                    let extracted = try output(outcome)
                    let upper = variant == "case" ? "Readme.txt" : "Folder/first.txt"
                    let lower = variant == "case" ? "readme.txt" : "folder/second.txt"
                    #expect(try Data(contentsOf: extracted.appending(path: upper)) == Data("FIRST".utf8))
                    #expect(try Data(contentsOf: extracted.appending(path: lower)) == Data("SECOND".utf8))
                } else {
                    guard
                        case .failed(.invalidInput(.archiveNameCollision(let first, let second))) = outcome.outcomes
                            .first
                    else {
                        Issue.record(
                            "Expected collision for \(filesystem) / \(format) / \(variant): \(outcome.outcomes)")
                        continue
                    }
                    #expect(first.hasPrefix("1:"))
                    #expect(second.hasPrefix("2:"))
                    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "bundle").path))
                    #expect(outcome.record == nil)
                    #expect(
                        !FileManager.default.fileExists(atPath: root.appending(path: "support/HatchExtractions").path))
                }
                #expect(try Data(contentsOf: source) == original)
            }
        }
        try volume.close()
    }

    @Test func nativeStreamingBackstopFailsInsteadOfSkippingOrOverwriting() async throws {
        let root = try TestVolume.makeFolder()
        let source = try reviewFixture("duplicate-cp932", in: root, format: "tar")
        let original = try Data(contentsOf: source)
        let (outcome, _, _, _) = try await run(source, in: root, native: true)
        guard case .failed(.invalidInput(.archiveNameCollision)) = outcome.outcomes.first else {
            Issue.record("Native collision was not refused: \(outcome.outcomes)")
            return
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "bundle").path))
        #expect(outcome.record == nil)
    }

    @Test func directoryMetadataAfterChildrenIsStillPreserved() async throws {
        let root = try TestVolume.makeFolder()
        let source = try reviewFixture("directory-metadata", in: root, format: "tar")
        let (outcome, _, _, _) = try await run(source, in: root, native: true)
        let extracted = try output(outcome)
        let directory = extracted.appending(path: "folder")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
        let modified = try #require(attributes[.modificationDate] as? Date)
        #expect(modified.timeIntervalSince1970 == 1_234_567_890)
        #expect(try Data(contentsOf: directory.appending(path: "child.txt")) == Data("FIRST".utf8))
    }

    @Test func TARAroundAZIPPayloadKeepsItsOuterFormat() async throws {
        let root = try TestVolume.makeFolder()
        let source = try reviewFixture("nested-zip", in: root, format: "tar")
        try ArchiveListing.verify(source, prefersJapanese: true)
        let (outcome, _, _, _) = try await run(source, in: root, native: true)
        let extracted = try output(outcome)
        let nested = extracted.appending(path: "nested.zip")
        #expect(try ArchiveBrowserZIP.list(nested).map(\.path) == ["file.txt"])
        let payload = root.appending(path: "payload.txt")
        try ArchiveBrowserZIP.extract(nested, ordinal: 0, to: payload, password: nil, limit: 100)
        #expect(try Data(contentsOf: payload) == Data("nested payload".utf8))
    }

    @Test(arguments: Array(65_516...65_535))
    func zip64LocatorUsesTheAbsoluteEndOffset(_ comment: Int) async throws {
        let root = try TestVolume.makeFolder()
        let source = try reviewFixture("zip64-comment", in: root, comment: comment)
        let original = try Data(contentsOf: source)
        #expect(try ArchiveNameInspection.inspect(source, prefersJapanese: true).needsLegacyDecoder)
        try ArchiveListing.verify(source, prefersJapanese: true)
        #expect(try ArchiveBrowserZIP.list(source, prefersJapanese: true).map(\.path) == ["資料.txt"])
        let (outcome, _, _, _) = try await run(source, in: root)
        let extracted = try output(outcome)
        #expect(try Data(contentsOf: extracted.appending(path: "資料.txt")) == Data("FIRST".utf8))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: ["symlink", "zip64-symlink"], [16_385, 65_535])
    func longZIPCommentsKeepLinksAndDecodeTheirTargets(variant: String, comment: Int) async throws {
        let root = try TestVolume.makeFolder()
        let source = try reviewFixture(variant, in: root, comment: comment)
        let original = try Data(contentsOf: source)
        let (outcome, _, _, _) = try await run(source, in: root)
        let extracted = try output(outcome)
        let link = extracted.appending(path: "別名")
        var metadata = stat()
        #expect(lstat(link.path, &metadata) == 0)
        #expect(metadata.st_mode & S_IFMT == S_IFLNK)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "資料.txt")
        for preference in [false, true] {
            #expect(throws: ZIPBrowserError.unsupportedEntry) {
                try ArchiveBrowserZIP.list(source, prefersJapanese: preference)
            }
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func DOSAttributesDoNotBecomeOversizedPOSIXLinks() async throws {
        let root = try TestVolume.makeFolder()
        let source = try reviewFixture("dos-file", in: root)
        #expect(try ArchiveNameInspection.inspect(source, prefersJapanese: true).unsupportedNativeFeature == nil)
        for preference in [false, true] {
            let entries = try ArchiveBrowserZIP.list(source, prefersJapanese: preference)
            #expect(entries.count == 1)
            let observedSize = try #require(entries.first?.size)
            let expectedSize: Int64 = 70 * 1024
            #expect(observedSize == expectedSize)
        }
        let (outcome, _, _, _) = try await run(source, in: root)
        let extracted = try output(outcome)
        #expect(try Data(contentsOf: extracted.appending(path: "資料.txt")) == Data(repeating: 0, count: 70 * 1024))
    }

    @Test(arguments: ["normal", "my.target", "backup.tar.old"])
    func SFXDetectionIgnoresParentDirectoryNames(_ parent: String) async throws {
        let root = try TestVolume.makeFolder().appending(path: parent)
        let source = try reviewFixture("sfx", in: root)
        #expect(try ArchiveNameInspection.inspect(source, prefersJapanese: true).needsLegacyDecoder)
        let (outcome, _, _, _) = try await run(source, in: root)
        let extracted = try output(outcome)
        #expect(try Data(contentsOf: extracted.appending(path: "資料.txt")) == Data("FIRST".utf8))
    }

    @Test(arguments: ["utf8-flag", "bad-unicode"], [false, true])
    func invalidUTF8DeclarationsFollowOneLegacyRule(_ variant: String, prefersJapanese: Bool) async throws {
        let root = try TestVolume.makeFolder()
        let source = try reviewFixture(variant, in: root)
        let original = try Data(contentsOf: source)
        let expected = prefersJapanese ? "資料.txt" : "Äæù┐.txt"
        let inspected = try ArchiveNameInspection.inspect(source, prefersJapanese: prefersJapanese)
        #expect(inspected.needsLegacyDecoder == prefersJapanese)
        #expect(try ArchiveBrowserZIP.list(source, prefersJapanese: prefersJapanese).map(\.path) == [expected])
        try ArchiveListing.verify(source, prefersJapanese: prefersJapanese)
        let destination = try reviewDestination(in: root, name: "direct")
        let layout = try ArchiveExtractor.extract(
            source, into: destination, rawName: "plain", password: nil, prefersJapanese: prefersJapanese
        ) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: destination.appending(path: expected)) == Data("FIRST".utf8))
        #expect(try Data(contentsOf: source) == original)
        let (outcome, _, _, _) = try await run(source, in: root, prefersJapanese: prefersJapanese)
        let extracted = try output(outcome)
        #expect(try Data(contentsOf: extracted.appending(path: expected)) == Data("FIRST".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path) == prefersJapanese)
    }

    @Test(arguments: ["zip", "tar"])
    func nativeExtractionAndVerificationResolveSourceSymlinks(_ format: String) throws {
        let root = try TestVolume.makeFolder()
        let source = try reviewFixture("normal", in: root, format: format)
        let linked = root.appending(path: "linked.\(format)")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
        try ArchiveListing.verify(linked, prefersJapanese: true)
        let destination = try reviewDestination(in: root, name: "output")
        let layout = try ArchiveExtractor.extract(
            linked, into: destination, rawName: "plain", password: nil, prefersJapanese: true
        ) { _ in }
        #expect(layout == .entries)
        #expect(try Data(contentsOf: destination.appending(path: "資料.txt")) == Data("FIRST".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path) == source.path)
    }

    @Test func helperLaunchRejectsAReplacementAfterInspection() async throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, encoding: "utf8")
        let marker = root.appending(path: "invoked")
        let target = root.appending(path: "output")
        let executable = try protocolExecutable(in: root, output: target, marker: marker)
        let changed = Mutex(false)
        let replacement = Data("replacement must not be consumed".utf8)
        let (outcome, _, _, _) = try await run(source, in: root, executable: executable) { progress in
            if progress.itemPhases.contains(.extractingInPlace) {
                changed.withLock { state in
                    guard !state else { return }
                    do { try replacement.write(to: source); state = true } catch { Issue.record(error) }
                }
            }
        }
        #expect(changed.withLock { $0 })
        #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        #expect(try Data(contentsOf: source) == replacement)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func locationRefusalPrecedesAnyArchiveRead() async throws {
        let root = try TestVolume.makeFolder().appending(path: "CloudStorage")
        let source = try reviewFixture("normal", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
        defer { chmod(source.path, 0o600) }
        let (outcome, _, _, _) = try await run(source, in: root)
        #expect(outcome.outcomes == [.failed(.unexpected("Cloud and network locations cannot be extracted in place"))])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "bundle").path))
    }

    @Test func missingProofDuringCleanupKeepsThePasswordError() async throws {
        let root = try TestVolume.makeFolder()
        let source = try fixture(in: root, encoding: "utf8")
        let script = root.appending(path: "remove-proof.py")
        try """
        #!/usr/bin/python3
        import json, pathlib, sys
        request = json.loads(sys.stdin.readline())
        pathlib.Path(request['directory'] + '.filenames.json').unlink()
        print(json.dumps({'event': 'passwordRequired'}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o700)
        let original = try Data(contentsOf: source)
        let (outcome, _, _, _) = try await run(source, in: root, executable: script)
        #expect(outcome.outcomes == [.failed(.invalidInput(.passwordRequired))])
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: ["large-utf8-tar", "large-cp932-tar", "large-cp932-invalid-tar"])
    func TARInspectionLimitsKeepTheCompatibleRoute(_ variant: String) async throws {
        let root = try TestVolume.makeFolder()
        let source = try reviewFixture(variant, in: root, format: "tar.gz")
        let original = try Data(contentsOf: source)
        let inspection = try ArchiveNameInspection.inspect(source, prefersJapanese: true)
        #expect(!inspection.inspectionComplete)
        #expect(inspection.needsLegacyDecoder == (variant != "large-utf8-tar"))
        if variant == "large-utf8-tar" {
            let marker = root.appending(path: "invoked")
            let target = root.appending(path: "helper-output", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let executable = try protocolExecutable(in: root, output: target, marker: marker)
            let (outcome, _, store, _) = try await run(source, in: root, executable: executable)
            #expect(try output(outcome) == target)
            #expect(outcome.record?.canUndo == false)
            #expect(FileManager.default.fileExists(atPath: marker.path))
            let proof = try #require(
                FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).first {
                    $0.pathExtension == "json"
                })
            let contents = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: proof)) as? [String: Any])
            #expect(contents["inspectionComplete"] as? Bool == false)
            #expect(try Data(contentsOf: source) == original)
            return
        }
        let (outcome, _, _, _) = try await run(source, in: root)
        if variant == "large-cp932-invalid-tar" {
            #expect(outcome.outcomes == [.failed(.invalidInput(.archiveNameEncodingUnsupported))])
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "bundle").path))
            #expect(outcome.record == nil)
        } else {
            let extracted = try output(outcome)
            #expect(try Data(contentsOf: extracted.appending(path: "資料.txt")) == Data("FIRST".utf8))
            #expect(try Data(contentsOf: extracted.appending(path: "last.txt")) == Data("SECOND".utf8))
            #expect(outcome.record?.canUndo == true)
        }
        #expect(try Data(contentsOf: source) == original)
    }
}
