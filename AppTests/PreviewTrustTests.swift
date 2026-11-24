import AppKit
import Darwin
import Engine
import Foundation
import UniformTypeIdentifiers
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

    func testWebPolicyHasOnlyRestrictedStaticAndInteractiveStates() {
        let standard = PreviewTrust(level: .standard, resolvedPath: "/tmp/page.html")
        let staticPolicy = PreviewWebPolicy(trust: standard, interactiveConsented: false)
        XCTAssertEqual(staticPolicy, .staticPreview)
        XCTAssertFalse(staticPolicy.allowsInteractive)
        XCTAssertTrue(staticPolicy.offersInteractive)

        let consented = PreviewWebPolicy(trust: standard, interactiveConsented: true)
        XCTAssertEqual(consented, .interactive)
        XCTAssertTrue(consented.allowsInteractive)
        XCTAssertFalse(consented.offersInteractive)

        let trusted = PreviewWebPolicy(
            trust: PreviewTrust(level: .trusted, resolvedPath: "/tmp/page.html"), interactiveConsented: false)
        XCTAssertEqual(trusted, .interactive)
        XCTAssertTrue(trusted.allowsInteractive)
        XCTAssertFalse(trusted.offersInteractive)

        let restricted = PreviewWebPolicy(
            trust: PreviewTrust(level: .restricted, resolvedPath: "/tmp/page.html"), interactiveConsented: true)
        XCTAssertEqual(restricted, .restricted)
        XCTAssertFalse(restricted.allowsInteractive)
        XCTAssertFalse(restricted.offersInteractive)
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

        // Unrestricted static Preview intentionally reads same-folder assets.
        let unquarantined = directory.appendingPathComponent("local.html")
        try FileManager.default.copyItem(at: page, to: unquarantined)
        removexattr(unquarantined.path, "com.apple.quarantine", 0)
        let resolvedLocal = unquarantined.resolvingSymlinksInPath().standardizedFileURL
        let readAccess = try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolvedLocal))
        let localStamp = try PreviewFileStamp(of: resolvedLocal)
        let standard = try await PreviewWebProbe.loading(
            .file(resolvedLocal, readAccess: readAccess, .staticPreview, expectedStamp: localStamp))
        let loadedWidth = try await standard.evaluate("document.getElementById('relative').naturalWidth")
        XCTAssertEqual(loadedWidth as? Int, 8, "intended: unrestricted Preview reads same-folder assets")
        let parentWidth = try await standard.evaluate("document.getElementById('parent').naturalWidth")
        XCTAssertEqual(parentWidth as? Int, 0, "parent folder assets must never load")
    }

    @MainActor
    func testStaticPreviewEmitsNoTrafficUnderNoInputRealInputAndAccessibilityAndInteractiveControlReachesListeners()
        async throws
    {
        let tcp = try LoopbackListener()
        let udp = try LoopbackUDPListener()
        let tcpPort = try await tcp.start()
        let udpPort = try await udp.start()
        defer {
            tcp.stop()
            udp.stop()
        }
        let directory = try PreviewFixtures.directory(self)
        let html = """
            <!DOCTYPE html><html><head><title>init</title>
            <base href="http://127.0.0.1:\(tcpPort)/base">
            <meta http-equiv="refresh" content="0;url=http://127.0.0.1:\(tcpPort)/meta">
            <link rel="dns-prefetch" href="//127.0.0.1:\(tcpPort)">
            <link rel="preconnect" href="http://127.0.0.1:\(tcpPort)">
            <link rel="prefetch" href="http://127.0.0.1:\(tcpPort)/prefetch">
            <link rel="stylesheet" href="http://127.0.0.1:\(tcpPort)/style.css">
            <style>
            @import url("http://127.0.0.1:\(tcpPort)/import.css");
            @font-face { font-family: RemoteF; src: url("http://127.0.0.1:\(tcpPort)/font.woff2"); }
            body { margin: 0; height: 1200px; font-family: RemoteF; background: url("http://127.0.0.1:\(tcpPort)/bg.png"); }
            </style></head>
            <body onload="window.__onload = true">
            <p id="copy">Readable static text</p>
            <a id="baseLink" href="#go" onclick="window.__clicked = true" style="display:block;width:200px;height:40px">Base Anchor</a>
            <a id="extLink" href="http://127.0.0.1:\(tcpPort)/ext" ping="http://127.0.0.1:\(tcpPort)/ping" style="display:block;width:200px;height:40px">External Link</a>
            <math id="mathRoot" href="http://127.0.0.1:\(tcpPort)/math-root"><mrow id="mathLink" href="http://127.0.0.1:\(tcpPort)/math"><mtext>Math Link</mtext></mrow></math>
            <div id="shadowHost"><template shadowrootmode="open"><a id="shadowLink" href="http://127.0.0.1:\(tcpPort)/shadow">Shadow Link</a></template></div>
            <div id="closedHost"><template shadowrootmode="closed"><a href="http://127.0.0.1:\(tcpPort)/closed" style="display:block;width:200px;height:24px">Closed Link</a><form action="http://127.0.0.1:\(tcpPort)/closed-form"><input name="q" value=""><button>Go</button></form><div contenteditable="true">closed editable</div></template></div>
            <div id="editable" contenteditable="true">light editable</div>
            <input id="field" value="">
            <img src="http://127.0.0.1:\(tcpPort)/img.png">
            <video src="http://127.0.0.1:\(tcpPort)/v.mp4" preload="auto"></video>
            <audio src="http://127.0.0.1:\(tcpPort)/a.mp3" preload="auto"></audio>
            <iframe src="http://127.0.0.1:\(tcpPort)/frame.html"></iframe>
            <form id="f" action="http://127.0.0.1:\(tcpPort)/form" method="POST"><button id="b" type="submit">Send</button></form>
            <script>
            (async () => {
              window.__ran = true;
              try { fetch('http://127.0.0.1:\(tcpPort)/fetch').catch(() => {}); } catch (e) {}
              try { const x = new XMLHttpRequest(); x.open('GET', 'http://127.0.0.1:\(tcpPort)/xhr'); x.send(); } catch (e) {}
              try { navigator.sendBeacon('http://127.0.0.1:\(tcpPort)/beacon', 'x'); } catch (e) {}
              try { new EventSource('http://127.0.0.1:\(tcpPort)/sse'); } catch (e) {}
              try { new WebSocket('ws://127.0.0.1:\(tcpPort)/ws'); } catch (e) {}
              try {
                new Worker(URL.createObjectURL(new Blob([
                  "fetch('http://127.0.0.1:\(tcpPort)/wf'); new WebSocket('ws://127.0.0.1:\(tcpPort)/wws');"
                ], {type: 'application/javascript'})));
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
            })();
            </script></body></html>
            """
        let page = directory.appendingPathComponent("hostile.html")
        try Data(html.utf8).write(to: page)
        let resolvedPage = page.resolvingSymlinksInPath().standardizedFileURL
        let readAccess = try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolvedPage))
        let pageStamp = try PreviewFileStamp(of: resolvedPage)

        // Static states: restricted (.generated) and standard (.staticPreview).
        let staticPages: [PreviewWebViewer.Page] = [
            .generated(html),
            .file(resolvedPage, readAccess: readAccess, .staticPreview, expectedStamp: pageStamp),
        ]
        for staticPage in staticPages {
            let probe = try await PreviewWebProbe.loading(staticPage)
            // No-input settle.
            try await probe.settle(.milliseconds(600))
            XCTAssertEqual(tcp.connectionCount, 0)
            XCTAssertEqual(udp.datagramCount, 0)

            let ran = try await probe.evaluate("Boolean(window.__ran || window.__onload || window.__clicked)") as? Bool
            XCTAssertEqual(ran, false)
            let title = try await probe.evaluate("document.title") as? String
            XCTAssertEqual(title, "init")

            // Real AppKit input on every activatable element.
            XCTAssertTrue(probe.focusWebView(), "static pages take focus so text can be selected")
            let startURL = probe.currentURL
            let navigationsBeforeInput = probe.requestedNavigationURLs.count
            for id in ["baseLink", "extLink", "mathLink", "shadowHost", "closedHost", "b", "field", "editable"] {
                let point = try await probe.center(of: "#\(id)", fromTop: id == "closedHost" ? 12 : nil)
                try probe.click(webPoint: point)
                try probe.click(webPoint: point, clickCount: 2)
                try probe.rightClick(webPoint: point)
                try probe.middleClick(webPoint: point)
                try probe.drag(from: point, to: NSPoint(x: point.x + 120, y: point.y + 30))
                try probe.pressKey("\r", keyCode: 36)
                try probe.pressKey(" ", keyCode: 49)
                try probe.pressKey("\t", keyCode: 48)
                try probe.type("zqx")
                try probe.scroll(deltaY: -80, at: point)
            }
            try await probe.settle(.milliseconds(600))
            XCTAssertEqual(tcp.connectionCount, 0)
            XCTAssertEqual(udp.datagramCount, 0)
            XCTAssertEqual(
                probe.requestedNavigationURLs.count, navigationsBeforeInput, "\(probe.requestedNavigationURLs)")
            XCTAssertEqual(probe.currentURL, startURL)
            XCTAssertEqual(probe.windowRequests, 0)
            XCTAssertEqual(probe.downloads, 0)
            let menuItems = Set(probe.shownMenuItems.joined())
            XCTAssertTrue(menuItems.isSubset(of: PreviewWebProbe.selectionMenuItems), "\(menuItems)")
            let afterInput = try await probe.evaluate(
                "JSON.stringify([Boolean(window.__ran || window.__onload || window.__clicked), document.title])")
            XCTAssertEqual(afterInput as? String, #"[false,"init"]"#)
            let typed = try await probe.find("zqx")
            XCTAssertFalse(typed.matchFound, "typing must not edit the page")

            // Accessibility reaches the page content directly.
            _ = probe.container.webView.accessibilityChildren()
            try await probe.settle(.milliseconds(300))
            let point = NSPoint(x: 40, y: 40)
            let webViewHit = try XCTUnwrap(probe.webViewAccessibilityHitTest(webPoint: point))
            let windowHit = try XCTUnwrap(probe.accessibilityHitTest(webPoint: point))
            XCTAssertTrue(windowHit.isEqual(webViewHit))
            XCTAssertTrue(
                windowHit === probe.container.webView
                    || NSStringFromClass(type(of: windowHit)) == "NSAccessibilityRemoteUIElement")
            let textAndLinks =
                try await probe.evaluate(
                    """
                    JSON.stringify({
                      text: document.body.innerText,
                      baseHref: document.getElementById('baseLink').getAttribute('href'),
                      extHref: document.getElementById('extLink').getAttribute('href'),
                      mathRootHref: document.getElementById('mathRoot').getAttribute('href'),
                      mathHref: document.getElementById('mathLink').getAttribute('href'),
                      mathAnyLink: document.getElementById('mathLink').matches(':any-link'),
                      shadowHref: document.getElementById('shadowHost').shadowRoot.getElementById('shadowLink').getAttribute('href'),
                      formAction: document.getElementById('f').getAttribute('action'),
                      buttonDisabled: document.getElementById('b').disabled
                    })
                    """
                ) as? String
            let snapshot = try XCTUnwrap(textAndLinks)
            XCTAssertTrue(snapshot.contains("Readable static text"), snapshot)
            XCTAssertTrue(snapshot.contains("External Link"), snapshot)
            XCTAssertTrue(snapshot.contains("Math Link"), snapshot)
            XCTAssertTrue(snapshot.contains("\"baseHref\":null"), snapshot)
            XCTAssertTrue(snapshot.contains("\"extHref\":null"), snapshot)
            XCTAssertTrue(snapshot.contains("\"mathRootHref\":null"), snapshot)
            XCTAssertTrue(snapshot.contains("\"mathHref\":null"), snapshot)
            XCTAssertTrue(snapshot.contains("\"mathAnyLink\":false"), snapshot)
            XCTAssertTrue(snapshot.contains("\"shadowHref\":null"), snapshot)
            XCTAssertTrue(snapshot.contains("\"formAction\":null"), snapshot)
            XCTAssertTrue(snapshot.contains("\"buttonDisabled\":true"), snapshot)

            let navsBeforeClick = probe.requestedNavigationURLs.count
            // Direct activation (like AXPress) emits zero traffic.
            _ = try await probe.evaluate(
                """
                document.getElementById('baseLink').click();
                document.getElementById('extLink').click();
                document.getElementById('mathLink').dispatchEvent(
                  new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
                document.getElementById('shadowHost').shadowRoot.getElementById('shadowLink').click();
                document.getElementById('b').click();
                """
            )
            try await probe.settle(.milliseconds(400))
            XCTAssertEqual(probe.requestedNavigationURLs.count, navsBeforeClick)
            XCTAssertEqual(tcp.connectionCount, 0)
            XCTAssertEqual(udp.datagramCount, 0)
        }

        // Control: interactive mode runs scripts and connects.
        let interactive = try await PreviewWebProbe.loading(
            .file(resolvedPage, readAccess: readAccess, .interactive, expectedStamp: pageStamp))
        try await interactive.settle(.milliseconds(1000))
        let interactiveRan = try await interactive.evaluate("window.__ran") as? Bool
        XCTAssertEqual(interactiveRan, true)
        XCTAssertGreaterThan(tcp.connectionCount, 0, "control: TCP listener observes allowed traffic")
        XCTAssertGreaterThan(udp.datagramCount, 0, "control: UDP listener observes WebRTC STUN")
        // Control: real clicks activate links here.
        try interactive.click(webPoint: try await interactive.center(of: "#closedHost", fromTop: 12))
        try await interactive.settle(.milliseconds(400))
        XCTAssertTrue(
            interactive.requestedNavigationURLs.contains { $0.path == "/closed" },
            "\(interactive.requestedNavigationURLs)")
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

        let probe = try await PreviewWebProbe.loading(.inline(html, .staticPreview))
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
        let pageStamp = try PreviewFileStamp(of: resolvedPage)
        let probe = try await PreviewWebProbe.loading(
            .file(resolvedPage, readAccess: readAccess, .staticPreview, expectedStamp: pageStamp))
        try await probe.settle()

        for id in ["nav", "blank", "dl", "jslink", "remote", "bOther", "bSelf"] {
            _ = try await probe.evaluate("document.getElementById('\(id)').click()")
        }
        _ = try await probe.evaluate("window.open('other.html')")
        try await probe.settle()

        let finalTitle = try await probe.evaluate("document.title") as? String
        XCTAssertEqual(probe.currentURL?.standardizedFileURL.path, resolvedPage.path)
        XCTAssertEqual(finalTitle, "stay")
        XCTAssertFalse(probe.didFail)
        XCTAssertEqual(tcp.connectionCount, 0)
    }

    @MainActor
    func testPerLoadPolicyEvaluatesFreshAfterReplacementEditQuarantineAndTrustedSwap() async throws {
        let root = try PreviewFixtures.directory(self)
        let directory = root.appendingPathComponent("site")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sibling = directory.appendingPathComponent("sibling.png")
        try PreviewFixtures.png().write(to: sibling)
        let page = directory.appendingPathComponent("page.html")
        try Data(
            "<html><head><title>a</title></head><body><img id='s' src='sibling.png'><script>document.title='a-ran'</script></body></html>"
                .utf8
        ).write(to: page)

        let first = try PreviewHTMLSnapshot.prepare(url: page, trustedFolders: [], scriptConsent: [])
        XCTAssertEqual(first.policy, .staticPreview)
        let keyA = try XCTUnwrap(first.trust.consentKey)
        let consent: Set<PreviewScriptConsentKey> = [keyA]

        // Consent applies to unchanged file A.
        let consentedA = try PreviewHTMLSnapshot.prepare(url: page, trustedFolders: [], scriptConsent: consent)
        XCTAssertEqual(consentedA.policy, .interactive)
        let pageA = try XCTUnwrap(consentedA.page)
        let probeA = try await PreviewWebProbe.loading(pageA)
        let titleA = try await probeA.evaluate("document.title") as? String
        XCTAssertEqual(titleA, "a-ran")

        // Replacing the file drops consent.
        let replacement = directory.appendingPathComponent("b.html")
        try Data(
            "<html><head><title>b</title></head><body><img id='s' src='sibling.png'><script>document.title='b-ran'</script></body></html>"
                .utf8
        ).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(page, withItemAt: replacement)

        // Stale prepared page refuses to load.
        let staleConfig = try await PreviewWebConfiguration.make(for: pageA)
        let staleWeb = PreviewWKWebView(frame: .zero, configuration: staleConfig)
        XCTAssertFalse(PreviewWebConfiguration.load(pageA, in: staleWeb))

        // Fresh prepare evaluates B as static.
        let reloadedB = try PreviewHTMLSnapshot.prepare(url: page, trustedFolders: [], scriptConsent: consent)
        XCTAssertEqual(reloadedB.policy, .staticPreview)
        let probeB = try await PreviewWebProbe.loading(try XCTUnwrap(reloadedB.page))
        let titleB = try await probeB.evaluate("document.title") as? String
        XCTAssertEqual(titleB, "b")

        // In-place edit drops consent.
        let keyB = try XCTUnwrap(reloadedB.trust.consentKey)
        let handle = try FileHandle(forWritingTo: page)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("<!-- edited -->".utf8))
        try handle.close()
        let editedB = try PreviewHTMLSnapshot.prepare(url: page, trustedFolders: [], scriptConsent: [keyB])
        XCTAssertEqual(editedB.policy, .staticPreview)
        let probeEdited = try await PreviewWebProbe.loading(try XCTUnwrap(editedB.page))
        let titleEdited = try await probeEdited.evaluate("document.title") as? String
        XCTAssertEqual(titleEdited, "b")

        // Trusted-folder file starts interactive until replaced.
        let trustedStart = try PreviewHTMLSnapshot.prepare(
            url: page, trustedFolders: [directory.path], scriptConsent: [])
        XCTAssertEqual(trustedStart.policy, .interactive)
        let trustedPage = try XCTUnwrap(trustedStart.page)
        let probeTrusted = try await PreviewWebProbe.loading(trustedPage)
        let titleTrusted = try await probeTrusted.evaluate("document.title") as? String
        XCTAssertEqual(titleTrusted, "b-ran")

        // Replacing with a quarantined file forces restricted.
        let downloaded = directory.appendingPathComponent("downloaded.html")
        try Data(
            "<html><head><title>q</title></head><body><img id='s' src='sibling.png'><script>document.title='q-ran'</script></body></html>"
                .utf8
        ).write(to: downloaded)
        try PreviewFixtures.quarantine(downloaded)
        _ = try FileManager.default.replaceItemAt(page, withItemAt: downloaded)
        XCTAssertFalse(PreviewWebConfiguration.load(trustedPage, in: staleWeb))
        let reloadedQuarantined = try PreviewHTMLSnapshot.prepare(
            url: page, trustedFolders: [directory.path], scriptConsent: [])
        XCTAssertEqual(reloadedQuarantined.policy, .restricted)
        let probeQuarantined = try await PreviewWebProbe.loading(try XCTUnwrap(reloadedQuarantined.page))
        let titleQuarantined = try await probeQuarantined.evaluate("document.title") as? String
        let siblingWidth = try await probeQuarantined.evaluate("document.getElementById('s').naturalWidth") as? Int
        XCTAssertEqual(titleQuarantined, "q")
        XCTAssertEqual(siblingWidth, 0)

        // Replacing with outside symlink drops to static.
        let externalFile = outside.appendingPathComponent("external.html")
        try Data(
            "<html><head><title>ext</title></head><body><script>document.title='ext-ran'</script></body></html>".utf8
        )
        .write(to: externalFile)
        try FileManager.default.removeItem(at: page)
        try FileManager.default.createSymbolicLink(at: page, withDestinationURL: externalFile)
        let reloadedOutside = try PreviewHTMLSnapshot.prepare(
            url: page, trustedFolders: [directory.path], scriptConsent: [])
        XCTAssertEqual(reloadedOutside.policy, .staticPreview)
        let probeOutside = try await PreviewWebProbe.loading(try XCTUnwrap(reloadedOutside.page))
        let titleOutside = try await probeOutside.evaluate("document.title") as? String
        XCTAssertEqual(titleOutside, "ext")
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

        // Descriptor-based snapshot path checks symlink quarantine too.
        let prepared = try PreviewHTMLSnapshot.prepare(url: link, trustedFolders: [directory.path], scriptConsent: [])
        XCTAssertEqual(prepared.trust.level, .restricted)
        XCTAssertEqual(prepared.policy, .restricted)
        guard case .generated = prepared.page else {
            return XCTFail("expected quarantined symlink to render as sealed .generated page")
        }
    }

    func testUnreadableQuarantineAttributeFailsClosedAsRestricted() throws {
        let directory = try PreviewFixtures.directory(self)
        let lockedFolder = directory.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: lockedFolder, withIntermediateDirectories: false)
        let page = lockedFolder.appendingPathComponent("page.html")
        try Data("<p>secret</p>".utf8).write(to: page)

        // Path-based EACCES fails closed as restricted.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedFolder.path) }
        XCTAssertEqual(PreviewTrust.evaluate(page, trustedFolders: [directory.path]).level, .restricted)

        // Path-based ENOENT fails closed as restricted.
        let missing = directory.appendingPathComponent("missing.html")
        XCTAssertEqual(PreviewTrust.evaluate(missing, trustedFolders: [directory.path]).level, .restricted)

        // Descriptor-based EBADF fails closed as restricted.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedFolder.path)
        var status = stat()
        XCTAssertEqual(stat(page.path, &status), 0)
        let resolved = page.resolvingSymlinksInPath().standardizedFileURL
        let badDescriptorTrust = PreviewTrust.evaluate(
            linkURL: page, resolvedURL: resolved, fileDescriptor: -1, status: status,
            trustedFolders: [directory.path])
        XCTAssertEqual(badDescriptorTrust.level, .restricted)
    }

    @MainActor
    func testInPlaceSameSizeEditWithRestoredMtimeInvalidatesPreviewConsentWithoutChangingEngineFileStamp() async throws
    {
        let directory = try PreviewFixtures.directory(self)
        let page = directory.appendingPathComponent("page.html")
        let payloadA = Data(
            "<html><head><title>A</title></head><body><script>document.title='A'</script></body></html>".utf8)
        let payloadB = Data(
            "<html><head><title>B</title></head><body><script>document.title='B'</script></body></html>".utf8)
        XCTAssertEqual(payloadA.count, payloadB.count)
        try payloadA.write(to: page)

        var originalStatus = stat()
        XCTAssertEqual(lstat(page.path, &originalStatus), 0)
        let originalEngineStamp = try FileStamp(of: page, includingIdentity: true)
        let first = try PreviewHTMLSnapshot.prepare(url: page, trustedFolders: [], scriptConsent: [])
        let keyA = try XCTUnwrap(first.trust.consentKey)
        let consented = try PreviewHTMLSnapshot.prepare(url: page, trustedFolders: [], scriptConsent: [keyA])
        XCTAssertEqual(consented.policy, .interactive)
        let consentedPage = try XCTUnwrap(consented.page)

        // Let ctime advance past creation.
        try await Task.sleep(for: .milliseconds(20))
        let fd = open(page.path, O_WRONLY | O_TRUNC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        payloadB.withUnsafeBytes { raw in
            XCTAssertEqual(Darwin.write(fd, raw.baseAddress, raw.count), payloadB.count)
        }
        close(fd)
        var times = [originalStatus.st_atimespec, originalStatus.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, page.path, &times, 0), 0)

        // Engine FileStamp stays unchanged; preview consent invalidates.
        XCTAssertEqual(try FileStamp(of: page, includingIdentity: true), originalEngineStamp)
        XCTAssertNotEqual(try PreviewFileStamp(of: page), keyA.stamp)

        let reloaded = try PreviewHTMLSnapshot.prepare(url: page, trustedFolders: [], scriptConsent: [keyA])
        XCTAssertEqual(reloaded.policy, .staticPreview)
        let staleConfig = try await PreviewWebConfiguration.make(for: consentedPage)
        let staleWeb = PreviewWKWebView(frame: .zero, configuration: staleConfig)
        XCTAssertFalse(PreviewWebConfiguration.load(consentedPage, in: staleWeb))
    }

    @MainActor
    func testFailClosedProxyBlocksHostNamedPreconnectOnMissedElement() async throws {
        let listener = try LoopbackListener()
        let port = try await listener.start()
        defer { listener.stop() }

        let directory = try PreviewFixtures.directory(self)
        let page = directory.appendingPathComponent("proxy-test.html")
        try Data("<!DOCTYPE html><html><body><p>Ready</p></body></html>".utf8).write(to: page)
        let resolved = page.resolvingSymlinksInPath().standardizedFileURL
        let readAccess = try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolved))
        let stamp = try PreviewFileStamp(of: resolved)

        // RFC 6761 subdomain stays local through proxy.
        let injectAndClick = """
            (() => {
              const a = document.createElement('a');
              a.href = 'https://probe.localhost:\(port)/missed';
              document.body.appendChild(a);
              a.click();
            })();
            """

        // Static preview installs the fail-closed SOCKS5 proxy.
        let staticProbe = try await PreviewWebProbe.loading(
            .file(resolved, readAccess: readAccess, .staticPreview, expectedStamp: stamp))
        _ = try await staticProbe.evaluate(injectAndClick)
        try await staticProbe.settle(.milliseconds(500))
        XCTAssertEqual(listener.connectionCount, 0)

        // Control: interactive mode omits the fail-closed proxy.
        let interactiveProbe = try await PreviewWebProbe.loading(
            .file(resolved, readAccess: readAccess, .interactive, expectedStamp: stamp))
        _ = try await interactiveProbe.evaluate(injectAndClick)
        try await interactiveProbe.settle(.milliseconds(500))
        XCTAssertGreaterThan(listener.connectionCount, 0)
    }

    @MainActor
    func testXHTMLWithInlineXSLTIsNeutralizedAndStaysOfflineInStaticPreview() async throws {
        XCTAssertEqual(PreviewKind.resolve(type: nil, extension: "xhtml"), .html)
        XCTAssertEqual(PreviewKind.resolve(type: .xml, extension: "xml"), .text)

        let tcp = try LoopbackListener()
        let port = try await tcp.start()
        defer { tcp.stop() }

        let directory = try PreviewFixtures.directory(self)
        let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <?xml-stylesheet type="text/xsl" href="#style"?>
            <!DOCTYPE doc [<!ATTLIST xsl:stylesheet id ID #IMPLIED>]>
            <doc>
              <xsl:stylesheet id="style" version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
                <xsl:template match="/">
                  <html><head><title>XSLT</title></head><body>
                    <img src="http://127.0.0.1:\(port)/ximg.png"/>
                    <a id="xl" href="http://127.0.0.1:\(port)/xl">XSLT Link</a>
                    <math><mrow id="xm" href="http://127.0.0.1:\(port)/xm"><mtext>XSLT Math</mtext></mrow></math>
                    <form id="xf" action="http://127.0.0.1:\(port)/xf"><button id="xb" type="submit">Go</button></form>
                    <script>window.__ran = true; document.title = "RAN";</script>
                  </body></html>
                </xsl:template>
              </xsl:stylesheet>
            </doc>
            """
        let file = directory.appendingPathComponent("transformed.xhtml")
        try Data(xhtml.utf8).write(to: file)

        let prepared = try PreviewHTMLSnapshot.prepare(url: file, trustedFolders: [], scriptConsent: [])
        XCTAssertEqual(prepared.policy, .staticPreview)
        let probe = try await PreviewWebProbe.loading(try XCTUnwrap(prepared.page))
        try await probe.settle(.milliseconds(500))

        let state =
            try await probe.evaluate(
                """
                JSON.stringify({
                  title: document.title,
                  xlHref: document.getElementById('xl')?.getAttribute('href'),
                  xmHref: document.getElementById('xm')?.getAttribute('href'),
                  xfAction: document.getElementById('xf')?.getAttribute('action'),
                  xbDisabled: document.getElementById('xb')?.disabled,
                  ran: Boolean(window.__ran)
                })
                """
            ) as? String
        let snapshot = try XCTUnwrap(state)
        XCTAssertTrue(snapshot.contains("\"title\":\"XSLT\""), snapshot)
        XCTAssertTrue(snapshot.contains("\"xlHref\":null"), snapshot)
        XCTAssertTrue(snapshot.contains("\"xmHref\":null"), snapshot)
        XCTAssertTrue(snapshot.contains("\"xfAction\":null"), snapshot)
        XCTAssertTrue(snapshot.contains("\"xbDisabled\":true"), snapshot)
        XCTAssertTrue(snapshot.contains("\"ran\":false"), snapshot)

        _ = try await probe.evaluate(
            """
            document.getElementById('xl').click();
            document.getElementById('xm').dispatchEvent(
              new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
            document.getElementById('xb').click();
            """
        )
        try await probe.settle(.milliseconds(400))
        XCTAssertEqual(tcp.connectionCount, 0)
    }

    @MainActor
    private func runSingleLayerLinkProbe(
        configuration: WKWebViewConfiguration,
        linksInDocument: Bool = false
    ) async throws -> (hostConnections: Int, loopbackConnections: Int, navigations: Int) {
        let hostListener = try LoopbackListener()
        let loopbackListener = try LoopbackListener()
        let hostPort = try await hostListener.start()
        let loopbackPort = try await loopbackListener.start()
        defer {
            hostListener.stop()
            loopbackListener.stop()
        }

        let directory = try PreviewFixtures.directory(self)
        let pageURL = directory.appendingPathComponent("layer-probe.html")
        let linkMarkup =
            linksInDocument
            ? """
            <a id="httpsHost" href="https://probe.localhost:\(hostPort)/https">https host</a>
            <a id="httpHost" href="http://probe.localhost:\(hostPort)/http">http host</a>
            <a id="loopback" href="http://127.0.0.1:\(loopbackPort)/ip">loopback</a>
            """ : "<p>Ready</p>"
        try Data("<!DOCTYPE html><html><body>\(linkMarkup)</body></html>".utf8).write(to: pageURL)
        let resolved = pageURL.resolvingSymlinksInPath().standardizedFileURL
        let readAccess = try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolved))
        let stamp = try PreviewFileStamp(of: resolved)
        let page = PreviewWebViewer.Page.file(resolved, readAccess: readAccess, .staticPreview, expectedStamp: stamp)

        let probe = try await PreviewWebProbe.loading(page, configuration: configuration)
        let triggerScript =
            linksInDocument
            ? """
            (() => {
              for (const id of ['httpsHost', 'httpHost', 'loopback']) {
                document.getElementById(id).click();
              }
            })();
            """
            : """
            (() => {
              const urls = [
                'https://probe.localhost:\(hostPort)/https',
                'http://probe.localhost:\(hostPort)/http',
                'http://127.0.0.1:\(loopbackPort)/ip'
              ];
              for (const href of urls) {
                const anchor = document.createElement('a');
                anchor.href = href;
                document.body.appendChild(anchor);
                anchor.click();
              }
            })();
            """
        _ = try await probe.evaluate(triggerScript)
        try await probe.settle(.milliseconds(600))
        return (hostListener.connectionCount, loopbackListener.connectionCount, probe.requestedNavigationURLs.count)
    }

    @MainActor
    func testSingleLayerFailClosedProxyBlocksHostNamesAlone() async throws {
        let configuration = HTMLDocument.isolatedConfiguration(allowsScripts: false)
        configuration.websiteDataStore.proxyConfigurations = [PreviewWebConfiguration.failClosedProxy]
        let measured = try await runSingleLayerLinkProbe(configuration: configuration)
        XCTAssertEqual(measured.hostConnections, 0, "proxy alone: \(measured)")
        XCTAssertGreaterThanOrEqual(measured.loopbackConnections, 1, "loopback residue: \(measured)")
        XCTAssertEqual(measured.navigations, 4, "proxy alone: \(measured)")
    }

    @MainActor
    func testSingleLayerActivationGuardBlocksClicksAlone() async throws {
        let configuration = HTMLDocument.isolatedConfiguration(allowsScripts: false)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: PreviewWebConfiguration.staticPreviewGuard, injectionTime: .atDocumentStart,
                forMainFrameOnly: false, in: .defaultClient))
        let measured = try await runSingleLayerLinkProbe(configuration: configuration)
        XCTAssertEqual(measured.hostConnections, 0, "guard alone: \(measured)")
        XCTAssertEqual(measured.loopbackConnections, 0, "guard alone: \(measured)")
        XCTAssertEqual(measured.navigations, 1, "guard alone: \(measured)")
    }

    @MainActor
    func testSingleLayerNeutralizerStripsStaticLinksAlone() async throws {
        let configuration = HTMLDocument.isolatedConfiguration(allowsScripts: false)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: PreviewWebConfiguration.staticPreviewNeutralizer, injectionTime: .atDocumentEnd,
                forMainFrameOnly: false, in: .defaultClient))
        let measured = try await runSingleLayerLinkProbe(configuration: configuration, linksInDocument: true)
        XCTAssertEqual(measured.hostConnections, 0, "neutralizer alone: \(measured)")
        XCTAssertEqual(measured.loopbackConnections, 0, "neutralizer alone: \(measured)")
        XCTAssertEqual(measured.navigations, 1, "neutralizer alone: \(measured)")
    }

    @MainActor
    func testSingleLayerContentRulesBlockSubresourcesAlone() async throws {
        let hostListener = try LoopbackListener()
        let loopbackListener = try LoopbackListener()
        let hostPort = try await hostListener.start()
        let loopbackPort = try await loopbackListener.start()
        defer {
            hostListener.stop()
            loopbackListener.stop()
        }

        let directory = try PreviewFixtures.directory(self)
        let pageURL = directory.appendingPathComponent("rules-probe.html")
        try Data(
            """
            <!DOCTYPE html><html><body>
            <img src="http://localhost:\(hostPort)/a.png">
            <img src="http://127.0.0.1:\(loopbackPort)/b.png">
            </body></html>
            """.utf8
        ).write(to: pageURL)
        let resolved = pageURL.resolvingSymlinksInPath().standardizedFileURL
        let readAccess = try XCTUnwrap(PreviewWebConfiguration.folderReadAccess(for: resolved))
        let stamp = try PreviewFileStamp(of: resolved)
        let page = PreviewWebViewer.Page.file(resolved, readAccess: readAccess, .staticPreview, expectedStamp: stamp)

        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let compiledRules = try await store.compileContentRuleList(
            forIdentifier: "MacEasePreviewOffline", encodedContentRuleList: PreviewWebConfiguration.offlineRules)
        let rules = try XCTUnwrap(compiledRules)
        let rulesOnly = HTMLDocument.isolatedConfiguration(allowsScripts: false)
        rulesOnly.userContentController.add(rules)
        let guarded = try await PreviewWebProbe.loading(page, configuration: rulesOnly)
        try await guarded.settle(.milliseconds(400))
        XCTAssertEqual(hostListener.connectionCount, 0)
        XCTAssertEqual(loopbackListener.connectionCount, 0)

        let unguarded = try await PreviewWebProbe.loading(
            page, configuration: HTMLDocument.isolatedConfiguration(allowsScripts: false))
        try await unguarded.settle(.milliseconds(400))
        XCTAssertGreaterThan(hostListener.connectionCount, 0)
        XCTAssertGreaterThan(loopbackListener.connectionCount, 0)
    }

    @MainActor
    func testAllLayersOffControlReachesBothHostAndLoopbackListeners() async throws {
        let configuration = HTMLDocument.isolatedConfiguration(allowsScripts: false)
        let measured = try await runSingleLayerLinkProbe(configuration: configuration)
        XCTAssertGreaterThan(measured.hostConnections, 0, "all off: \(measured)")
        XCTAssertGreaterThanOrEqual(measured.loopbackConnections, 1, "all off: \(measured)")
        XCTAssertEqual(measured.navigations, 4, "all off: \(measured)")
    }

    @MainActor
    func testXHTMLForeignNamespaceElementDoesNotStopNeutralizer() async throws {
        let directory = try PreviewFixtures.directory(self)
        let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:x="urn:example:foreign">
            <head><title>Foreign</title></head>
            <body>
              <x:a id="foreignLink" href="https://example.com/foreign">Foreign</x:a>
              <a id="laterLink" href="https://example.com/later">Later</a>
              <form id="laterForm" action="https://example.com/submit">
                <button id="laterButton" type="submit">Send</button>
              </form>
              <div id="laterEditable" contenteditable="true">Edit me</div>
            </body>
            </html>
            """
        let file = directory.appendingPathComponent("foreign.xhtml")
        try Data(xhtml.utf8).write(to: file)
        let prepared = try PreviewHTMLSnapshot.prepare(url: file, trustedFolders: [], scriptConsent: [])
        let probe = try await PreviewWebProbe.loading(try XCTUnwrap(prepared.page))

        let state =
            try await probe.evaluate(
                """
                JSON.stringify({
                  foreignHref: document.getElementById('foreignLink').getAttribute('href'),
                  laterHref: document.getElementById('laterLink').getAttribute('href'),
                  laterTitle: document.getElementById('laterLink').title,
                  formAction: document.getElementById('laterForm').getAttribute('action'),
                  buttonDisabled: document.getElementById('laterButton').disabled,
                  editable: document.getElementById('laterEditable').getAttribute('contenteditable')
                })
                """
            ) as? String
        let snapshot = try XCTUnwrap(state)
        XCTAssertTrue(snapshot.contains("\"foreignHref\":null"), snapshot)
        XCTAssertTrue(snapshot.contains("\"laterHref\":null"), snapshot)
        XCTAssertTrue(snapshot.contains("\"laterTitle\":\"https://example.com/later\""), snapshot)
        XCTAssertTrue(snapshot.contains("\"formAction\":null"), snapshot)
        XCTAssertTrue(snapshot.contains("\"buttonDisabled\":true"), snapshot)
        XCTAssertTrue(snapshot.contains("\"editable\":null"), snapshot)
    }

    @MainActor
    func testDragStartCancelsLinksImagesShadowRootsAndMathMLButAllowsPlainText() async throws {
        let pngBase64 = try PreviewFixtures.png(width: 24, height: 24).base64EncodedString()
        let html = """
            <!DOCTYPE html><html><body style="margin:0;font:16px sans-serif">
            <p id="plain" style="margin:8px">Plain selectable text here</p>
            <a id="lightLink" href="https://example.com/light">Light Link</a>
            <img id="lightImg" src="data:image/png;base64,\(pngBase64)" width="24" height="24">
            <math id="mathRoot" href="https://example.com/math-root"><mrow id="mathLink" href="https://example.com/math"><mtext>Math Link</mtext></mrow></math>
            <div id="openHost"><template shadowrootmode="open"><a id="openLink" href="https://example.com/open">Open Link</a><img id="openImg" src="data:image/png;base64,\(pngBase64)" width="24" height="24"><p id="openText">Open plain text</p></template></div>
            <div id="closedHost" style="height:60px"><template shadowrootmode="closed"><a href="https://example.com/closed" style="display:block;height:28px">Closed Link</a><img src="data:image/png;base64,\(pngBase64)" width="24" height="24"></template></div>
            </body></html>
            """
        let probe = try await PreviewWebProbe.loading(.inline(html, .staticPreview))
        let result =
            try await probe.evaluate(
                """
                (() => {
                  const check = (node) => {
                    const event = new Event('dragstart', {bubbles: true, cancelable: true, composed: true});
                    node.dispatchEvent(event);
                    return event.defaultPrevented;
                  };
                  const openRoot = document.getElementById('openHost').shadowRoot;
                  return JSON.stringify({
                    plainText: check(document.getElementById('plain').firstChild),
                    openPlainText: check(openRoot.getElementById('openText').firstChild),
                    lightLink: check(document.getElementById('lightLink').firstChild),
                    lightImg: check(document.getElementById('lightImg')),
                    mathRoot: check(document.getElementById('mathRoot')),
                    mathLink: check(document.getElementById('mathLink').firstChild),
                    openLink: check(openRoot.getElementById('openLink').firstChild),
                    openImg: check(openRoot.getElementById('openImg')),
                    closedHost: check(document.getElementById('closedHost'))
                  });
                })()
                """
            ) as? String
        let snapshot = try XCTUnwrap(result)
        XCTAssertTrue(snapshot.contains("\"plainText\":false"), snapshot)
        XCTAssertTrue(snapshot.contains("\"openPlainText\":false"), snapshot)
        XCTAssertTrue(snapshot.contains("\"lightLink\":true"), snapshot)
        XCTAssertTrue(snapshot.contains("\"lightImg\":true"), snapshot)
        XCTAssertTrue(snapshot.contains("\"mathRoot\":true"), snapshot)
        XCTAssertTrue(snapshot.contains("\"mathLink\":true"), snapshot)
        XCTAssertTrue(snapshot.contains("\"openLink\":true"), snapshot)
        XCTAssertTrue(snapshot.contains("\"openImg\":true"), snapshot)
        XCTAssertTrue(snapshot.contains("\"closedHost\":true"), snapshot)

        // Real drags cancel closed shadow, allow text.
        _ = try await probe.evaluate(
            """
            window.__drags = [];
            window.addEventListener('dragstart', (event) => {
              window.__drags.push({
                target: event.target?.id || event.target?.nodeName,
                prevented: event.defaultPrevented
              });
            }, false);
            true;
            """
        )
        XCTAssertTrue(probe.focusWebView())
        let closedLinkPoint = try await probe.center(of: "#closedHost", fromTop: 12)
        try probe.drag(from: closedLinkPoint, to: NSPoint(x: closedLinkPoint.x + 80, y: closedLinkPoint.y + 20))
        let closedImgPoint = try await probe.center(of: "#closedHost", fromTop: 40)
        try probe.drag(from: closedImgPoint, to: NSPoint(x: closedImgPoint.x + 80, y: closedImgPoint.y + 20))
        let dragsCaptured = try await PreviewFixtures.waitUntil {
            (try await probe.evaluate("window.__drags.length") as? Int ?? 0) >= 2
        }
        XCTAssertTrue(dragsCaptured)
        let realDrags = try await probe.evaluate("JSON.stringify(window.__drags)") as? String
        let dragsJSON = try XCTUnwrap(realDrags)
        XCTAssertFalse(dragsJSON.contains("\"prevented\":false"), dragsJSON)

        let plainPoint = try await probe.center(of: "#plain")
        try probe.click(webPoint: plainPoint, clickCount: 2)
        let selected = try await PreviewFixtures.waitUntil {
            !((try await probe.evaluate("getSelection().toString()") as? String) ?? "").isEmpty
        }
        XCTAssertTrue(selected)
        let dragsBeforePlain = try await probe.evaluate("window.__drags.length") as? Int ?? 0
        try probe.drag(from: plainPoint, to: NSPoint(x: plainPoint.x + 120, y: plainPoint.y + 30))
        try await probe.nextFrame()
        let plainDrags =
            try await probe.evaluate("JSON.stringify(window.__drags.slice(\(dragsBeforePlain)))") as? String
        let plainDragsJSON = try XCTUnwrap(plainDrags)
        XCTAssertFalse(plainDragsJSON.contains("\"prevented\":true"), plainDragsJSON)
    }

    @MainActor
    func testStaticPreviewBlocksModifierClicksAccessKeysLabelForAreaSVGAndSubframes() async throws {
        let tcp = try LoopbackListener()
        let port = try await tcp.start()
        defer { tcp.stop() }
        let directory = try PreviewFixtures.directory(self)
        let sibling = directory.appendingPathComponent("subframe.html")
        try Data("<html><body><p>subframe loaded</p></body></html>".utf8).write(to: sibling)
        let pngBase64 = try PreviewFixtures.png(width: 80, height: 30).base64EncodedString()
        let pageURL = directory.appendingPathComponent("coverage.html")
        try Data(
            """
            <!DOCTYPE html><html><body style="margin:0">
            <a id="modLink" href="http://127.0.0.1:\(port)/mod" style="display:block;width:120px;height:24px">Mod</a>
            <a id="akLink" accesskey="k" href="http://127.0.0.1:\(port)/ak" style="display:block;width:120px;height:24px">AK</a>
            <form id="lblForm" action="http://127.0.0.1:\(port)/lbl">
              <label id="lbl" for="sub" style="display:block;width:120px;height:24px">Label Submit</label>
              <input id="sub" type="submit" value="Go">
            </form>
            <img id="mapImg" usemap="#m" width="80" height="30" src="data:image/png;base64,\(pngBase64)">
            <map name="m"><area id="mapArea" shape="rect" coords="0,0,80,30" href="http://127.0.0.1:\(port)/area"></map>
            <svg width="160" height="30" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
              <a id="svgLink" href="http://127.0.0.1:\(port)/svg"><text x="4" y="20">SVG</text></a>
              <a id="svgXlink" xlink:href="http://127.0.0.1:\(port)/svgx"><text x="60" y="20">XLink</text></a>
            </svg>
            <iframe id="remoteFrame" src="http://127.0.0.1:\(port)/frame"></iframe>
            <iframe id="localFrame" src="subframe.html"></iframe>
            </body></html>
            """.utf8
        ).write(to: pageURL)

        let prepared = try PreviewHTMLSnapshot.prepare(url: pageURL, trustedFolders: [], scriptConsent: [])
        let probe = try await PreviewWebProbe.loading(try XCTUnwrap(prepared.page))
        XCTAssertTrue(probe.focusWebView())
        let navsBefore = probe.requestedNavigationURLs.count

        let modPoint = try await probe.center(of: "#modLink")
        for modifiers: NSEvent.ModifierFlags in [[.command], [.shift], [.option], [.command, .shift]] {
            try probe.click(webPoint: modPoint, modifiers: modifiers)
        }
        try probe.pressKey("k", keyCode: 40, modifiers: [.control, .option])
        try probe.click(webPoint: try await probe.center(of: "#lbl"))
        try probe.click(webPoint: try await probe.center(of: "#mapImg"))
        try probe.click(webPoint: try await probe.center(of: "#svgLink"))
        try probe.click(webPoint: try await probe.center(of: "#svgXlink"))
        try await probe.settle(.milliseconds(300))

        let state =
            try await probe.evaluate(
                """
                JSON.stringify({
                  areaHref: document.getElementById('mapArea').getAttribute('href'),
                  svgHref: document.getElementById('svgLink').getAttribute('href'),
                  svgTitleAttr: document.getElementById('svgLink').getAttribute('title'),
                  svgTitleProp: document.getElementById('svgLink').title ?? null,
                  svgTitleChild: document.getElementById('svgLink').querySelector('title')?.textContent ?? null,
                  svgXlinkHref: document.getElementById('svgXlink').getAttributeNS('http://www.w3.org/1999/xlink', 'href'),
                  svgXlinkTitleChild: document.getElementById('svgXlink').querySelector('title')?.textContent ?? null,
                  localFrameText: (() => {
                    try { return document.getElementById('localFrame').contentDocument?.body?.innerText ?? ''; }
                    catch { return 'blocked'; }
                  })()
                })
                """
            ) as? String
        let snapshot = try XCTUnwrap(state)
        XCTAssertTrue(snapshot.contains("\"areaHref\":null"), snapshot)
        XCTAssertTrue(snapshot.contains("\"svgHref\":null"), snapshot)
        XCTAssertTrue(snapshot.contains("\"svgTitleAttr\":null"), snapshot)
        XCTAssertTrue(snapshot.contains("\"svgTitleProp\":null"), snapshot)
        XCTAssertTrue(snapshot.contains("\"svgTitleChild\":\"http://127.0.0.1:\(port)/svg\""), snapshot)
        XCTAssertTrue(snapshot.contains("\"svgXlinkHref\":null"), snapshot)
        XCTAssertTrue(snapshot.contains("\"svgXlinkTitleChild\":\"http://127.0.0.1:\(port)/svgx\""), snapshot)
        XCTAssertFalse(snapshot.contains("subframe loaded"), snapshot)
        XCTAssertEqual(probe.requestedNavigationURLs.count, navsBefore, "\(probe.requestedNavigationURLs)")
        XCTAssertEqual(probe.windowRequests, 0)
        XCTAssertEqual(probe.downloads, 0)
        XCTAssertEqual(tcp.connectionCount, 0)
    }

    @MainActor
    func testStaticPreviewRefusesPasteCutUndoAndDrops() async throws {
        let html = """
            <!DOCTYPE html><html><body style="margin:0">
            <div id="editable" contenteditable="true" style="height:24px">initial</div>
            <input id="field" value="fixed" style="height:24px">
            </body></html>
            """
        let probe = try await PreviewWebProbe.loading(.inline(html, .staticPreview))
        XCTAssertTrue(probe.focusWebView())
        XCTAssertTrue(probe.container.webView.registeredDraggedTypes.isEmpty)
        XCTAssertEqual(probe.container.webView.draggingEntered(StubDraggingInfo()), [])

        let pasteboard = NSPasteboard.general
        let savedPasteboard = (pasteboard.pasteboardItems ?? []).map { pasteboardItem in
            let copy = NSPasteboardItem()
            for type in pasteboardItem.types {
                if let bytes = pasteboardItem.data(forType: type) { copy.setData(bytes, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedPasteboard)
        }
        pasteboard.clearContents()
        pasteboard.setString("INJECTED", forType: .string)

        let editPoint = try await probe.center(of: "#editable")
        try probe.click(webPoint: editPoint, clickCount: 2)
        _ = NSApp.sendAction(#selector(NSText.cut(_:)), to: probe.container.webView, from: nil)
        _ = NSApp.sendAction(#selector(NSText.paste(_:)), to: probe.container.webView, from: nil)
        _ = probe.container.webView.tryToPerform(Selector(("undo:")), with: nil)
        let fieldPoint = try await probe.center(of: "#field")
        try probe.click(webPoint: fieldPoint)
        _ = NSApp.sendAction(#selector(NSText.paste(_:)), to: probe.container.webView, from: nil)
        try await probe.nextFrame()

        let unchanged =
            try await probe.evaluate(
                "JSON.stringify([document.getElementById('editable').textContent, document.getElementById('field').value])"
            ) as? String
        XCTAssertEqual(unchanged, #"["initial","fixed"]"#)
    }

    @MainActor
    func testStaticPreviewHidesShareMenuOnImagesAndClosedShadowLinks() async throws {
        let pngBase64 = try PreviewFixtures.png(width: 60, height: 40).base64EncodedString()
        let html = """
            <!DOCTYPE html><html><body style="margin:0">
            <img id="pic" src="data:image/png;base64,\(pngBase64)" width="60" height="40" style="display:block">
            <div id="closedHost" style="height:30px"><template shadowrootmode="closed"><a href="https://example.com/secret" style="display:block;height:30px">Closed Link</a></template></div>
            </body></html>
            """
        let probe = try await PreviewWebProbe.loading(.inline(html, .staticPreview))
        XCTAssertTrue(probe.focusWebView())
        let picPoint = try await probe.center(of: "#pic")
        let closedPoint = try await probe.center(of: "#closedHost", fromTop: 12)
        let menusBefore = probe.shownMenuItems.count
        try probe.rightClick(webPoint: picPoint)
        try await probe.settle(.milliseconds(200))
        try probe.rightClick(webPoint: closedPoint)
        try await probe.settle(.milliseconds(200))
        let newMenus = Array(probe.shownMenuItems.dropFirst(menusBefore))
        for menu in newMenus {
            XCTAssertFalse(menu.contains("WKMenuItemIdentifierShareMenu"), "\(menu)")
            XCTAssertTrue(Set(menu).isSubset(of: PreviewWebProbe.selectionMenuItems), "\(menu)")
        }
    }
}

private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { .general }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
