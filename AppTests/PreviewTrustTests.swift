import Foundation
import WebKit
import XCTest

@testable import MacEase

final class PreviewTrustTests: XCTestCase {
    func testQuarantinedFileIsRestrictedAndOthersAreStandard() throws {
        let directory = try PreviewFixtures.directory(self)
        let plain = directory.appendingPathComponent("plain.html")
        let downloaded = directory.appendingPathComponent("downloaded.html")
        try Data("<p>x</p>".utf8).write(to: plain)
        try Data("<p>x</p>".utf8).write(to: downloaded)
        try PreviewFixtures.quarantine(downloaded)

        XCTAssertEqual(PreviewTrust.evaluate(plain, trustedFolders: []).level, .standard)
        XCTAssertEqual(PreviewTrust.evaluate(downloaded, trustedFolders: []).level, .restricted)
    }

    func testQuarantineWinsOverTrustedFolder() throws {
        let directory = try PreviewFixtures.directory(self)
        let downloaded = directory.appendingPathComponent("page.html")
        try Data("<p>x</p>".utf8).write(to: downloaded)
        try PreviewFixtures.quarantine(downloaded)

        XCTAssertEqual(PreviewTrust.evaluate(downloaded, trustedFolders: [directory.path]).level, .restricted)
    }

    func testSymlinkIsJudgedByItsTarget() throws {
        let directory = try PreviewFixtures.directory(self)
        let trusted = directory.appendingPathComponent("trusted")
        let outside = directory.appendingPathComponent("outside")
        for folder in [trusted, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let target = trusted.appendingPathComponent("page.html")
        try Data("<p>x</p>".utf8).write(to: target)
        let link = outside.appendingPathComponent("link.html")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let trust = PreviewTrust.evaluate(link, trustedFolders: [trusted.path])
        XCTAssertEqual(trust.level, .trusted)
        XCTAssertEqual(trust.resolvedPath, target.resolvingSymlinksInPath().path)

        let escaping = trusted.appendingPathComponent("escape.html")
        let foreign = outside.appendingPathComponent("foreign.html")
        try Data("<p>x</p>".utf8).write(to: foreign)
        try FileManager.default.createSymbolicLink(at: escaping, withDestinationURL: foreign)
        XCTAssertEqual(PreviewTrust.evaluate(escaping, trustedFolders: [trusted.path]).level, .standard)

        try PreviewFixtures.quarantine(target)
        XCTAssertEqual(PreviewTrust.evaluate(link, trustedFolders: [trusted.path]).level, .restricted)
    }

    func testContainmentComparesWholePathComponents() throws {
        let directory = try PreviewFixtures.directory(self)
        let folder = directory.appendingPathComponent("b")
        let sibling = directory.appendingPathComponent("bc")
        for item in [folder, sibling] {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        }
        let inside = folder.appendingPathComponent("page.html")
        let beside = sibling.appendingPathComponent("page.html")
        try Data("<p>x</p>".utf8).write(to: inside)
        try Data("<p>x</p>".utf8).write(to: beside)

        XCTAssertEqual(PreviewTrust.evaluate(inside, trustedFolders: [folder.path]).level, .trusted)
        XCTAssertEqual(PreviewTrust.evaluate(beside, trustedFolders: [folder.path]).level, .standard)
    }

    func testFolderNamedWithSpacesDoesNotTrustItsParent() throws {
        let directory = try PreviewFixtures.directory(self)
        let spaced = directory.appendingPathComponent(" ", isDirectory: true)
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: false)
        let sibling = directory.appendingPathComponent("sibling.html")
        let inside = spaced.appendingPathComponent("page.html")
        try Data("<p>x</p>".utf8).write(to: sibling)
        try Data("<p>x</p>".utf8).write(to: inside)

        var settings = FinderPreviewSettings()
        settings.addTrustedFolder(spaced)
        XCTAssertEqual(settings.trustedFolders, [directory.path + "/ "])
        XCTAssertEqual(PreviewTrust.evaluate(sibling, trustedFolders: settings.trustedFolders).level, .standard)
        XCTAssertEqual(PreviewTrust.evaluate(inside, trustedFolders: settings.trustedFolders).level, .trusted)
    }

    func testWebPolicyOnlyWidensAndNetworkImpliesScripts() {
        let standard = PreviewTrust(level: .standard, resolvedPath: "/tmp/page.html")
        var policy = PreviewWebPolicy(trust: standard, scriptsConsented: false)
        XCTAssertFalse(policy.scripts)
        XCTAssertFalse(policy.network)
        XCTAssertTrue(policy.offersScripts)
        XCTAssertTrue(policy.offersNetwork)

        policy.allowNetwork()
        XCTAssertTrue(policy.scripts)
        XCTAssertTrue(policy.network)
        XCTAssertFalse(policy.offersScripts)
        XCTAssertFalse(policy.offersNetwork)

        var scriptsOnly = PreviewWebPolicy(trust: standard, scriptsConsented: false)
        scriptsOnly.allowScripts()
        XCTAssertTrue(scriptsOnly.scripts)
        XCTAssertFalse(scriptsOnly.network)
        XCTAssertTrue(scriptsOnly.offersNetwork)
    }

    func testTrustedOrConsentedFilesStartWithScriptsButNeverNetwork() {
        let trusted = PreviewWebPolicy(
            trust: PreviewTrust(level: .trusted, resolvedPath: "/tmp/page.html"), scriptsConsented: false)
        XCTAssertTrue(trusted.scripts)
        XCTAssertFalse(trusted.network)
        let consented = PreviewWebPolicy(
            trust: PreviewTrust(level: .standard, resolvedPath: "/tmp/page.html"), scriptsConsented: true)
        XCTAssertTrue(consented.scripts)
        XCTAssertFalse(consented.network)
    }

    func testRestrictedPolicyCannotBeWidened() {
        var policy = PreviewWebPolicy(
            trust: PreviewTrust(level: .restricted, resolvedPath: "/tmp/page.html"), scriptsConsented: true)
        XCTAssertFalse(policy.scripts)
        XCTAssertFalse(policy.offersScripts)
        XCTAssertFalse(policy.offersNetwork)
        policy.allowScripts()
        policy.allowNetwork()
        XCTAssertFalse(policy.scripts)
        XCTAssertFalse(policy.network)
    }

    @MainActor
    func testRestrictedPreviewCannotReadSiblingFilesRunScriptsOrReachTheNetwork() async throws {
        let listener = try LoopbackListener()
        let port = try await listener.start()
        defer { listener.stop() }
        let directory = try PreviewFixtures.directory(self)
        let sibling = directory.appendingPathComponent("sibling.png")
        try PreviewFixtures.png().write(to: sibling)
        let page = directory.appendingPathComponent("page.html")
        try Data(
            """
            <html><head><title>Page</title></head><body>
            <img id="relative" src="sibling.png"><img id="absolute" src="\(sibling.absoluteString)">
            <img src="http://127.0.0.1:\(port)/remote.png">
            <iframe src="http://127.0.0.1:\(port)/frame.html"></iframe>
            <script>document.title = "ran";</script></body></html>
            """.utf8
        ).write(to: page)
        try PreviewFixtures.quarantine(page)
        let trust = PreviewTrust.evaluate(page, trustedFolders: [directory.path])
        XCTAssertTrue(trust.restricted)

        let rendering = try PreviewTextRendering.make(
            source: try PreviewTextSource.read(page), encoding: .automatic, rich: true, kind: .html, url: page,
            restricted: trust.restricted)
        XCTAssertTrue(rendering.html)
        let restricted = try await PreviewWebProbe.loading(.generated(rendering.text))
        try await restricted.settle()
        for image in ["relative", "absolute"] {
            let width = try await restricted.evaluate("document.getElementById('\(image)').naturalWidth")
            XCTAssertEqual(width as? Int, 0, image)
        }
        let title = try await restricted.evaluate("document.title")
        XCTAssertEqual(title as? String, "Page")
        XCTAssertEqual(listener.connectionCount, 0)

        let standard = try await PreviewWebProbe.loading(
            .file(
                page,
                PreviewWebPolicy(
                    trust: PreviewTrust(level: .standard, resolvedPath: page.path), scriptsConsented: false)))
        let loadedWidth = try await standard.evaluate("document.getElementById('relative').naturalWidth")
        XCTAssertEqual(loadedWidth as? Int, 8, "control: a standard page reads its folder")
    }

    @MainActor
    func testLoopbackListenerSeesRequestsWhenNetworkIsAllowed() async throws {
        let listener = try LoopbackListener()
        let port = try await listener.start()
        defer { listener.stop() }
        let directory = try PreviewFixtures.directory(self)
        let page = directory.appendingPathComponent("page.html")
        try Data("<img src=\"http://127.0.0.1:\(port)/remote.png\">".utf8).write(to: page)
        var policy = PreviewWebPolicy(
            trust: PreviewTrust(level: .standard, resolvedPath: page.path), scriptsConsented: false)
        policy.allowNetwork()
        let probe = try await PreviewWebProbe.loading(.file(page, policy))
        try await probe.settle()
        XCTAssertGreaterThan(listener.connectionCount, 0, "control: the listener observes allowed requests")
    }
}
