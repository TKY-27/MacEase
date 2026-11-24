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
        let root = try PreviewFixtures.directory(self)
        let parentImage = root.appendingPathComponent("parent.png")
        try PreviewFixtures.png().write(to: parentImage)
        let directory = root.appendingPathComponent("site")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let sibling = directory.appendingPathComponent("sibling.png")
        try PreviewFixtures.png().write(to: sibling)
        let page = directory.appendingPathComponent("page.html")
        try Data(
            """
            <html><head><title>Page</title></head><body>
            <img id="relative" src="sibling.png"><img id="absolute" src="\(sibling.absoluteString)">
            <img id="parent" src="../parent.png">
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
        for image in ["relative", "absolute", "parent"] {
            let width = try await restricted.evaluate("document.getElementById('\(image)').naturalWidth")
            XCTAssertEqual(width as? Int, 0, image)
        }
        let title = try await restricted.evaluate("document.title")
        XCTAssertEqual(title as? String, "Page")
        XCTAssertEqual(listener.connectionCount, 0)

        // Unrestricted Preview intentionally reads its own folder.
        let resolvedPage = page.resolvingSymlinksInPath().standardizedFileURL
        let readAccess = try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolvedPage))
        let standard = try await PreviewWebProbe.loading(
            .file(
                resolvedPage, readAccess: readAccess,
                PreviewWebPolicy(
                    trust: PreviewTrust(level: .standard, resolvedPath: resolvedPage.path), scriptsConsented: false)))
        let loadedWidth = try await standard.evaluate("document.getElementById('relative').naturalWidth")
        XCTAssertEqual(loadedWidth as? Int, 8, "intended: unrestricted Preview reads same-folder assets")
        let parentWidth = try await standard.evaluate("document.getElementById('parent').naturalWidth")
        XCTAssertEqual(parentWidth as? Int, 0, "parent folder assets must never load")
    }

    @MainActor
    func testLoopbackListenerSeesRequestsWhenNetworkIsAllowed() async throws {
        let listener = try LoopbackListener()
        let port = try await listener.start()
        defer { listener.stop() }
        let directory = try PreviewFixtures.directory(self)
        let page = directory.appendingPathComponent("page.html")
        try Data("<img src=\"http://127.0.0.1:\(port)/remote.png\">".utf8).write(to: page)
        let resolvedPage = page.resolvingSymlinksInPath().standardizedFileURL
        let readAccess = try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolvedPage))
        var policy = PreviewWebPolicy(
            trust: PreviewTrust(level: .standard, resolvedPath: resolvedPage.path), scriptsConsented: false)
        policy.allowNetwork()
        let probe = try await PreviewWebProbe.loading(.file(resolvedPage, readAccess: readAccess, policy))
        try await probe.settle()
        XCTAssertGreaterThan(listener.connectionCount, 0, "control: the listener observes allowed requests")
    }

    @MainActor
    func testScriptedOfflinePreviewBlocksAllNetworkEgress() async throws {
        let tcp = try LoopbackListener()
        let udp = try LoopbackUDPListener()
        let tcpPort = try await tcp.start()
        let udpPort = try await udp.start()
        defer {
            tcp.stop()
            udp.stop()
        }
        let directory = try PreviewFixtures.directory(self)
        let page = directory.appendingPathComponent("hostile.html")
        try Data(
            """
            <!DOCTYPE html><html><head><title>init</title>
            <meta http-equiv="refresh" content="0;url=http://127.0.0.1:\(tcpPort)/meta">
            <link rel="dns-prefetch" href="//127.0.0.1:\(tcpPort)">
            <link rel="preconnect" href="http://127.0.0.1:\(tcpPort)">
            <link rel="prefetch" href="http://127.0.0.1:\(tcpPort)/prefetch">
            <link rel="stylesheet" href="http://127.0.0.1:\(tcpPort)/style.css">
            <style>
            @import url("http://127.0.0.1:\(tcpPort)/import.css");
            @font-face { font-family: RemoteF; src: url("http://127.0.0.1:\(tcpPort)/font.woff2"); }
            body { font-family: RemoteF; background: url("http://127.0.0.1:\(tcpPort)/bg.png"); }
            </style></head><body>
            <img src="http://127.0.0.1:\(tcpPort)/img.png">
            <video src="http://127.0.0.1:\(tcpPort)/v.mp4" preload="auto"></video>
            <audio src="http://127.0.0.1:\(tcpPort)/a.mp3" preload="auto"></audio>
            <form id="f" action="http://127.0.0.1:\(tcpPort)/form" method="POST"><input name="k" value="v"></form>
            <a id="ping" href="#here" ping="http://127.0.0.1:\(tcpPort)/ping">ping</a>
            <script>
            (async () => {
              window.__report = {
                js: true,
                rtc: typeof RTCPeerConnection,
                wt: typeof WebTransport,
                sw: typeof navigator.serviceWorker
              };
              try { fetch('http://127.0.0.1:\(tcpPort)/fetch').catch(() => {}); } catch (e) {}
              try { const x = new XMLHttpRequest(); x.open('GET', 'http://127.0.0.1:\(tcpPort)/xhr'); x.send(); } catch (e) {}
              try { navigator.sendBeacon('http://127.0.0.1:\(tcpPort)/beacon', 'x'); } catch (e) {}
              try { new EventSource('http://127.0.0.1:\(tcpPort)/sse'); } catch (e) {}
              try { new WebSocket('ws://127.0.0.1:\(tcpPort)/ws'); } catch (e) {}
              try { import('http://127.0.0.1:\(tcpPort)/mod.js').catch(() => {}); } catch (e) {}
              try {
                new Worker(URL.createObjectURL(new Blob([
                  "fetch('http://127.0.0.1:\(tcpPort)/wf'); new WebSocket('ws://127.0.0.1:\(tcpPort)/wws');"
                ], {type: 'application/javascript'})));
              } catch (e) {}
              try {
                if (typeof WebTransport !== 'undefined') {
                  new WebTransport('https://127.0.0.1:\(tcpPort)/wt');
                }
              } catch (e) {}
              try {
                if (typeof RTCPeerConnection !== 'undefined') {
                  const pc = new RTCPeerConnection({iceServers: [
                    {urls: 'stun:127.0.0.1:\(udpPort)'},
                    {urls: 'turn:127.0.0.1:\(tcpPort)?transport=tcp', username: 'u', credential: 'p'}
                  ]});
                  pc.createDataChannel('d');
                  await pc.setLocalDescription(await pc.createOffer());
                }
              } catch (e) {}
              try { document.getElementById('ping').click(); } catch (e) {}
              try { document.getElementById('f').submit(); } catch (e) {}
              try { window.open('http://127.0.0.1:\(tcpPort)/popup'); } catch (e) {}
              try { location.href = 'http://127.0.0.1:\(tcpPort)/nav'; } catch (e) {}
            })();
            </script></body></html>
            """.utf8
        ).write(to: page)

        let resolvedPage = page.resolvingSymlinksInPath().standardizedFileURL
        let readAccess = try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolvedPage))
        var offlineScripts = PreviewWebPolicy(
            trust: PreviewTrust(level: .standard, resolvedPath: resolvedPage.path), scriptsConsented: false)
        offlineScripts.allowScripts()
        let offline = try await PreviewWebProbe.loading(.file(resolvedPage, readAccess: readAccess, offlineScripts))
        try await offline.settle(.milliseconds(1000))

        let rawReport = try await offline.evaluate("JSON.stringify(window.__report)") as? String
        let report = try XCTUnwrap(rawReport)
        XCTAssertTrue(report.contains("\"js\":true"), report)
        XCTAssertTrue(report.contains("\"rtc\":\"undefined\""), report)
        XCTAssertTrue(report.contains("\"wt\":\"undefined\""), report)
        XCTAssertTrue(report.contains("\"sw\":\"undefined\""), report)
        XCTAssertEqual(offline.currentURL?.standardizedFileURL.path, resolvedPage.path)
        XCTAssertEqual(tcp.connectionCount, 0, "offline scripted page must emit zero TCP traffic")
        XCTAssertEqual(udp.datagramCount, 0, "offline scripted page must emit zero UDP traffic")

        // Control: network reaches TCP and UDP listeners.
        var onlineScripts = offlineScripts
        onlineScripts.allowNetwork()
        let online = try await PreviewWebProbe.loading(.file(resolvedPage, readAccess: readAccess, onlineScripts))
        try await online.settle(.milliseconds(1000))
        XCTAssertGreaterThan(tcp.connectionCount, 0, "control: TCP listener observes allowed traffic")
        XCTAssertGreaterThan(udp.datagramCount, 0, "control: UDP listener observes WebRTC STUN")
    }

    @MainActor
    func testFolderReadAccessDeniesHomeAndAncestorsAndSealsInlineHTML() async throws {
        let fakeHome = try PreviewFixtures.directory(self)
        let directInHome = fakeHome.appendingPathComponent("home-page.html")
        let siblingInHome = fakeHome.appendingPathComponent("secret.png")
        let subfolder = fakeHome.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
        let insideSubfolder = subfolder.appendingPathComponent("index.html")
        try PreviewFixtures.png().write(to: siblingInHome)
        let html = """
            <html><body>
            <img id="rel" src="secret.png">
            <img id="abs" src="\(siblingInHome.absoluteString)">
            </body></html>
            """
        try Data(html.utf8).write(to: directInHome)
        try Data(html.utf8).write(to: insideSubfolder)

        XCTAssertNil(PreviewWebConfiguration.folderReadAccess(for: directInHome, homeDirectory: fakeHome))
        XCTAssertNil(
            PreviewWebConfiguration.folderReadAccess(
                for: fakeHome.deletingLastPathComponent().appendingPathComponent("x.html"), homeDirectory: fakeHome))
        XCTAssertNil(
            PreviewWebConfiguration.folderReadAccess(
                for: URL(fileURLWithPath: "/page.html"), homeDirectory: fakeHome))
        XCTAssertEqual(
            PreviewWebConfiguration.folderReadAccess(for: insideSubfolder, homeDirectory: fakeHome)?.path,
            subfolder.resolvingSymlinksInPath().standardizedFileURL.path)

        let policy = PreviewWebPolicy(
            trust: PreviewTrust(level: .standard, resolvedPath: directInHome.path), scriptsConsented: false)
        let probe = try await PreviewWebProbe.loading(.inline(html, policy))
        try await probe.settle()
        let relativeWidth = try await probe.evaluate("document.getElementById('rel').naturalWidth") as? Int
        let absoluteWidth = try await probe.evaluate("document.getElementById('abs').naturalWidth") as? Int
        XCTAssertEqual(relativeWidth, 0)
        XCTAssertEqual(absoluteWidth, 0)
    }

    @MainActor
    func testProductionDelegatesBlockFormsNavigationPopupsDownloadsAndScriptlessPayloads() async throws {
        let tcp = try LoopbackListener()
        let port = try await tcp.start()
        defer { tcp.stop() }
        let directory = try PreviewFixtures.directory(self)
        let other = directory.appendingPathComponent("other.html")
        try Data("<html><head><title>other</title></head><body>other</body></html>".utf8).write(to: other)
        let page = directory.appendingPathComponent("page.html")
        try Data(
            """
            <!DOCTYPE html><html><head><title>stay</title>
            <meta http-equiv="refresh" content="0;url=other.html">
            </head><body>
            <iframe src="data:text/html,<script>top.document.title='data-ran'</script>"></iframe>
            <iframe srcdoc="<script>parent.document.title='srcdoc-ran'</script>"></iframe>
            <a id="nav" href="other.html">other</a>
            <a id="blank" href="other.html" target="_blank">blank</a>
            <a id="dl" href="other.html" download="other.html">dl</a>
            <a id="jslink" href="javascript:document.title='jslink'">js</a>
            <a id="remote" href="http://127.0.0.1:\(port)/click">remote</a>
            <form id="fOther" action="other.html" method="POST"><button id="bOther" type="submit">go</button></form>
            <form id="fSelf" action="page.html" method="POST"><button id="bSelf" type="submit">self</button></form>
            </body></html>
            """.utf8
        ).write(to: page)

        let resolvedPage = page.resolvingSymlinksInPath().standardizedFileURL
        let readAccess = try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolvedPage))
        let policy = PreviewWebPolicy(
            trust: PreviewTrust(level: .standard, resolvedPath: resolvedPage.path), scriptsConsented: false)
        let probe = try await PreviewWebProbe.loading(.file(resolvedPage, readAccess: readAccess, policy))
        try await probe.settle()

        for id in ["nav", "blank", "dl", "jslink", "bOther", "bSelf"] {
            _ = try await probe.evaluate("document.getElementById('\(id)').click()")
        }
        let remoteRect =
            try await probe.evaluate(
                "(() => { const r = document.getElementById('remote').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()"
            ) as? [Double]
        let coords = try XCTUnwrap(remoteRect)
        try probe.click(webPoint: NSPoint(x: coords[0], y: coords[1]))
        _ = try await probe.evaluate("window.open('other.html')")
        try await probe.settle()

        let finalTitle = try await probe.evaluate("document.title") as? String
        XCTAssertEqual(probe.currentURL?.standardizedFileURL.path, resolvedPage.path)
        XCTAssertEqual(finalTitle, "stay")
        XCTAssertFalse(probe.didFail)
        XCTAssertEqual(tcp.connectionCount, 0)
    }

    @MainActor
    func testScriptConsentInvalidatesWhenFileIsReplacedOrEdited() async throws {
        let directory = try PreviewFixtures.directory(self)
        let page = directory.appendingPathComponent("page.html")
        try Data("<html><head><title>a</title></head><body><script>document.title='a-ran'</script></body></html>".utf8)
            .write(to: page)

        let trustA = PreviewTrust.evaluate(page, trustedFolders: [])
        let keyA = try XCTUnwrap(trustA.consentKey)
        let consent: Set<PreviewScriptConsentKey> = [keyA]

        // Reselecting unchanged file A keeps script consent.
        let trustASame = PreviewTrust.evaluate(page, trustedFolders: [])
        let policySame = PreviewWebPolicy(
            trust: trustASame, scriptsConsented: trustASame.consentKey.map(consent.contains) ?? false)
        XCTAssertTrue(policySame.scripts)
        let resolved = page.resolvingSymlinksInPath().standardizedFileURL
        let readAccess = try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolved))
        let probeA = try await PreviewWebProbe.loading(.file(resolved, readAccess: readAccess, policySame))
        let titleA = try await probeA.evaluate("document.title") as? String
        XCTAssertEqual(titleA, "a-ran")

        // Replacing file A invalidates script consent.
        let replacement = directory.appendingPathComponent("replacement.html")
        try Data("<html><head><title>b</title></head><body><script>document.title='b-ran'</script></body></html>".utf8)
            .write(to: replacement)
        _ = try FileManager.default.replaceItemAt(page, withItemAt: replacement)

        let trustB = PreviewTrust.evaluate(page, trustedFolders: [])
        let policyB = PreviewWebPolicy(
            trust: trustB, scriptsConsented: trustB.consentKey.map(consent.contains) ?? false)
        XCTAssertFalse(policyB.scripts)
        XCTAssertTrue(policyB.offersScripts)
        let probeB = try await PreviewWebProbe.loading(.file(resolved, readAccess: readAccess, policyB))
        let titleB = try await probeB.evaluate("document.title") as? String
        XCTAssertEqual(titleB, "b")

        // Editing in place also invalidates consent.
        let keyB = try XCTUnwrap(trustB.consentKey)
        let consentB: Set<PreviewScriptConsentKey> = [keyB]
        let handle = try FileHandle(forWritingTo: page)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("<!-- changed -->".utf8))
        try handle.close()

        let trustBEdited = PreviewTrust.evaluate(page, trustedFolders: [])
        let policyBEdited = PreviewWebPolicy(
            trust: trustBEdited, scriptsConsented: trustBEdited.consentKey.map(consentB.contains) ?? false)
        XCTAssertFalse(policyBEdited.scripts)
    }

    func testQuarantinedSymlinkIsRestrictedEvenWhenTargetIsNot() throws {
        let directory = try PreviewFixtures.directory(self)
        let target = directory.appendingPathComponent("clean.html")
        try Data("<p>clean</p>".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.html")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let value = Array("0083;00000000;Safari;".utf8)
        XCTAssertEqual(setxattr(link.path, "com.apple.quarantine", value, value.count, 0, XATTR_NOFOLLOW), 0)

        XCTAssertEqual(PreviewTrust.evaluate(target, trustedFolders: [directory.path]).level, .trusted)
        XCTAssertEqual(PreviewTrust.evaluate(link, trustedFolders: [directory.path]).level, .restricted)
    }

    @MainActor
    func testOfflinePreviewIsViewOnlyAtAppKitLevelAndBlocksBaseAndShadowLinkClicks() async throws {
        let tcp = try LoopbackListener()
        let udp = try LoopbackUDPListener()
        let tcpPort = try await tcp.start()
        _ = try await udp.start()
        defer {
            tcp.stop()
            udp.stop()
        }
        let directory = try PreviewFixtures.directory(self)
        let baseHTML = """
            <!DOCTYPE html><html><head><base href="http://127.0.0.1:\(tcpPort)/base"></head>
            <body style="margin:0;height:1200px">
            <a id="target" href="#go" style="display:block;width:200px;height:100px;background:#09f">go</a>
            </body></html>
            """
        let shadowHTML = """
            <!DOCTYPE html><html><body style="margin:0;height:1200px">
            <div id="host" style="width:200px;height:100px"></div>
            <script>
            const shadow = document.getElementById('host').attachShadow({mode: 'open'});
            shadow.innerHTML = '<a id="shadowLink" href="http://127.0.0.1:\(tcpPort)/shadow" style="display:block;width:200px;height:100px;background:#f90">shadow</a>';
            </script></body></html>
            """
        let baseFile = directory.appendingPathComponent("base.html")
        let shadowFile = directory.appendingPathComponent("shadow.html")
        try Data(baseHTML.utf8).write(to: baseFile)
        try Data(shadowHTML.utf8).write(to: shadowFile)
        let resolvedBase = baseFile.resolvingSymlinksInPath().standardizedFileURL
        let resolvedShadow = shadowFile.resolvingSymlinksInPath().standardizedFileURL
        let readAccess = try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolvedBase))

        let plainPolicy = PreviewWebPolicy(
            trust: PreviewTrust(level: .standard, resolvedPath: resolvedBase.path), scriptsConsented: false)
        var scriptedPolicy = plainPolicy
        scriptedPolicy.allowScripts()

        let offlinePages: [PreviewWebViewer.Page] = [
            .generated(baseHTML),
            .file(resolvedBase, readAccess: readAccess, plainPolicy),
            .file(resolvedBase, readAccess: readAccess, scriptedPolicy),
            .file(resolvedShadow, readAccess: readAccess, scriptedPolicy),
        ]
        let linkPoint = NSPoint(x: 40, y: 40)
        for page in offlinePages {
            let probe = try await PreviewWebProbe.loading(page)
            try await probe.settle(.milliseconds(200))
            XCTAssertTrue(probe.hitTest(webPoint: linkPoint) === probe.container.inputShield)
            XCTAssertFalse(probe.attemptFocusWebView())
            try probe.click(webPoint: linkPoint)
            try probe.rightClick(webPoint: linkPoint)
            try probe.drag(from: linkPoint, to: NSPoint(x: 120, y: 120))
            try probe.pressKey("\r", keyCode: 36)
            try probe.pressKey(" ", keyCode: 49)
            try probe.scroll(deltaY: -80, at: linkPoint)
            try await probe.settle(.milliseconds(400))
            XCTAssertEqual(tcp.connectionCount, 0)
            XCTAssertEqual(udp.datagramCount, 0)
        }

        // Control: allowed network clicks reach the listener.
        var onlinePolicy = scriptedPolicy
        onlinePolicy.allowNetwork()
        for file in [resolvedBase, resolvedShadow] {
            let before = tcp.connectionCount
            let online = try await PreviewWebProbe.loading(.file(file, readAccess: readAccess, onlinePolicy))
            try await online.settle(.milliseconds(200))
            XCTAssertTrue(online.hitTest(webPoint: linkPoint) !== online.container.inputShield)
            try online.click(webPoint: linkPoint)
            try await online.settle(.milliseconds(600))
            XCTAssertGreaterThan(
                tcp.connectionCount, before, "control: allowed click reaches listener for \(file.lastPathComponent)")
        }
    }

    @MainActor
    func testProgrammaticAnchorClicksEmitNoTrafficOffline() async throws {
        let tcp = try LoopbackListener()
        let port = try await tcp.start()
        defer { tcp.stop() }
        let directory = try PreviewFixtures.directory(self)
        let page = directory.appendingPathComponent("programmatic.html")
        try Data(
            """
            <!DOCTYPE html><html><head><base href="http://127.0.0.1:\(port)/ext"></head><body>
            <a id="base" href="#go">go</a>
            <a id="abs" href="http://127.0.0.1:\(port)/abs">abs</a>
            <div id="host"></div>
            <script>
              window.__ran = true;
              document.getElementById('base').click();
              document.getElementById('abs').click();
              const s = document.getElementById('host').attachShadow({mode: 'closed'});
              const a = document.createElement('a');
              a.href = 'http://127.0.0.1:\(port)/shadow';
              s.appendChild(a);
              a.click();
              const d = document.createElement('a');
              d.href = 'http://127.0.0.1:\(port)/detached';
              d.click();
              d.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}));
            </script></body></html>
            """.utf8
        ).write(to: page)
        let resolved = page.resolvingSymlinksInPath().standardizedFileURL
        let readAccess = try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolved))
        var policy = PreviewWebPolicy(
            trust: PreviewTrust(level: .standard, resolvedPath: resolved.path), scriptsConsented: false)
        policy.allowScripts()
        let probe = try await PreviewWebProbe.loading(.file(resolved, readAccess: readAccess, policy))
        try await probe.settle(.milliseconds(700))
        let ran = try await probe.evaluate("window.__ran") as? Bool
        XCTAssertEqual(ran, true)
        XCTAssertEqual(tcp.connectionCount, 0)
    }
}
