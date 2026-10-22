import Testing

@testable import Engine

@Suite struct SubtitleConversionTests {
    @Test func acceptsMinuteOnlyWebVTTTimestamps() throws {
        #expect(
            try SubtitleConversion.convert("WEBVTT\n\n00:01.025 --> 00:02.500\nx\n", fromVTT: true)
                == "1\n00:00:01,025 --> 00:00:02,500\nx\n")
    }

    @Test func rejectsEntitiesThatBecomeSRTMarkup() {
        #expect(throws: EngineError.invalidInput(.malformed("decoded subtitle text would become SRT styling"))) {
            try SubtitleConversion.convert(
                "WEBVTT\n\n00:01.000 --> 00:02.000\n&lt;b&gt;text&lt;/b&gt;\n", fromVTT: true)
        }
    }

    @Test func convertsSRTToVTTAndEscapesPlainText() throws {
        let source = "1\r\n00:00:01,025 --> 00:00:02,500\r\nA & < B >\r\nsecond line\r\n"
        #expect(
            try SubtitleConversion.convert(source, fromVTT: false)
                == "WEBVTT\n\n00:00:01.025 --> 00:00:02.500\nA &amp; &lt; B &gt;\nsecond line\n")
    }

    @Test func convertsVTTToSRTAndDecodesEntities() throws {
        let source = "\u{FEFF}WEBVTT\n\n00:00:01.025 --> 00:00:02.500\nA &amp; &lt; B&gt; &gt; C\n"
        #expect(
            try SubtitleConversion.convert(source, fromVTT: true)
                == "1\n00:00:01,025 --> 00:00:02,500\nA & < B> > C\n")
    }

    @Test func preservesOverlappingCuesAndExactMilliseconds() throws {
        let source = "1\n00:00:00,001 --> 00:00:02,002\none\n\n2\n00:00:01,001 --> 00:00:03,009\ntwo\n"
        #expect(
            try SubtitleConversion.convert(source, fromVTT: false)
                == "WEBVTT\n\n00:00:00.001 --> 00:00:02.002\none\n\n00:00:01.001 --> 00:00:03.009\ntwo\n")
    }

    @Test func refusesMalformedTimingAndOrdering() {
        for source in [
            "1\n00:00:01,000 --> 00:00:01,000\nx\n",
            "1\n00:00:02,000 --> 00:00:01,999\nx\n",
            "1\n00:60:00,000 --> 00:61:00,000\nx\n",
            "1\n00:00,01:000 --> 00:00:02,000\nx\n",
            "1\n10000:00:00,000 --> 10000:00:01,000\nx\n",
            "1\n0:00:00,000 --> 00:00:01,000\nx\n",
        ] {
            #expect(throws: EngineError.self) { try SubtitleConversion.convert(source, fromVTT: false) }
        }
    }

    @Test func refusesUnsupportedMetadataSettingsMarkupAndIdentifiers() {
        let inputs = [
            ("1\n00:00:00,000 --> 00:00:01,000 align:start\nx\n", false),
            ("2\n00:00:00,000 --> 00:00:01,000\nx\n", false),
            ("1\n00:00:00,000 --> 00:00:01,000\n<i>x</i>\n", false),
            ("WEBVTT\n\nNOTE note\nx\n", true),
            ("WEBVTT\n\nSTYLE\n::cue { color: red }\n", true),
            ("WEBVTT\n\n00:00:00.000 --> 00:00:01.000 align:start\nx\n", true),
            ("WEBVTT\n\ncaption\n00:00:00.000 --> 00:00:01.000\nx\n", true),
        ]
        for (source, fromVTT) in inputs {
            #expect(throws: EngineError.self) { try SubtitleConversion.convert(source, fromVTT: fromVTT) }
        }
    }

    @Test func refusesInputAndLineLimits() {
        #expect(throws: EngineError.self) {
            try SubtitleConversion.convert(
                String(repeating: "x", count: 8 * 1_024 * 1_024 + 1), fromVTT: false)
        }
        let longText =
            "1\n00:00:00,000 --> 00:00:01,000\n" + String(repeating: "x", count: 65_537) + "\n"
        #expect(throws: EngineError.self) { try SubtitleConversion.convert(longText, fromVTT: false) }
    }

    @Test func refusesCueLimit() {
        let cues = (1...100_001).map { index in
            "\(index)\n00:00:00,000 --> 00:00:01,000\nx"
        }.joined(separator: "\n\n")
        #expect(throws: EngineError.self) { try SubtitleConversion.convert(cues, fromVTT: false) }
    }
}
