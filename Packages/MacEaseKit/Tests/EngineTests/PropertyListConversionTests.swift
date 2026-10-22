import CoreFoundation
import Darwin
import Foundation
import Testing

@testable import Engine

@Suite struct PropertyListConversionTests {
    @Test(arguments: [PropertyListSerialization.PropertyListFormat.binary, .xml])
    func roundTripsDatesDataBooleansAndInteger(format: PropertyListSerialization.PropertyListFormat)
        throws
    {
        let date = Date(timeIntervalSince1970: format == .binary ? 1_700_000_000.125 : 1_700_000_000)
        let input: [String: Any] = [
            "bytes": Data([0, 1, 255]),
            "enabled": true,
            "count": Int64.max,
            "created": date,
        ]
        let source = try PropertyListSerialization.data(
            fromPropertyList: input, format: format, options: 0)
        let json = try PropertyListConversion.json(from: source, indent: "  ")
        let result = try PropertyListConversion.plist(from: json, format: format)
        var decodedFormat = PropertyListSerialization.PropertyListFormat.xml
        let decoded = try #require(
            PropertyListSerialization.propertyList(from: result, options: [], format: &decodedFormat)
                as? [String: Any])
        #expect((decoded["bytes"] as? Data) == Data([0, 1, 255]))
        #expect(
            (decoded["enabled"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true)
        #expect((decoded["count"] as? NSNumber)?.int64Value == Int64.max)
        #expect((decoded["created"] as? Date) == date)
    }

    @Test func preservesDictionariesThatUseTheReservedTagKey() throws {
        let binary = try PropertyListSerialization.data(
            fromPropertyList: ["$maceaseType": "date", "value": "ordinary text"], format: .binary, options: 0)
        let json = try PropertyListConversion.json(from: binary, indent: "")
        let restored = try PropertyListConversion.plist(from: json, format: .binary)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let value = try PropertyListSerialization.propertyList(
            from: restored, options: [], format: &format)
        #expect((value as? [String: String]) == ["$maceaseType": "date", "value": "ordinary text"])
    }

    @Test(arguments: [PropertyListSerialization.PropertyListFormat.binary, .xml])
    func keepsBooleanIntegerAndRealTypesDistinct(format: PropertyListSerialization.PropertyListFormat) throws {
        let bytes = try PropertyListConversion.plist(from: "[true,1,1.0]", format: format)
        let json = try PropertyListConversion.json(from: bytes, indent: "")
        #expect(json.filter { !$0.isWhitespace } == "[true,1,1.0]")
    }

    @Test func refusesXMLDatePrecisionLoss() {
        let json = #"{"$maceaseType":"date","value":"2023-11-14T22:13:20.125Z"}"#
        #expect(
            throws: EngineError.invalidInput(
                .malformed("This property list format cannot preserve the supplied values"))
        ) {
            try PropertyListConversion.plist(from: json, format: .xml)
        }
    }

    @Test(arguments: [0.001, 1_700_000_000.123])
    func preservesMillisecondDates(_ seconds: TimeInterval) throws {
        let original = Date(timeIntervalSince1970: seconds)
        let bytes = try PropertyListSerialization.data(fromPropertyList: [original], format: .binary, options: 0)
        let json = try PropertyListConversion.json(from: bytes, indent: "")
        let restored = try PropertyListConversion.plist(from: json, format: .binary)
        let dates = try #require(
            PropertyListSerialization.propertyList(from: restored, options: [], format: nil) as? [Date])
        #expect(dates == [original])
    }

    @Test func refusesPrecisionLossAndNonFiniteNumbers() throws {
        let json = "0.123456789012345678901234567890123456789"
        #expect(throws: EngineError.invalidInput(.malformed("Number cannot be represented without precision loss"))) {
            try PropertyListConversion.plist(from: json, format: .binary)
        }
        let binary = try PropertyListSerialization.data(
            fromPropertyList: [Double.infinity], format: .binary, options: 0)
        #expect(throws: EngineError.invalidInput(.malformed("Non-finite numbers are unsupported"))) {
            try PropertyListConversion.json(from: binary, indent: "")
        }
    }

    @Test func ordersKeysByUnicodeScalars() throws {
        let binary = try PropertyListSerialization.data(
            fromPropertyList: ["z": 1, "A": 2, "a": 3], format: .binary, options: 0)
        #expect(
            try PropertyListConversion.json(from: binary, indent: "").filter { !$0.isWhitespace }
                == #"{"A":2,"a":3,"z":1}"#)
    }

    @Test(arguments: ["null", #"{"a":null}"#, #"{"a":1,"a":2}"#, "9223372036854775808", "1e400"])
    func rejectsValuesWithoutStrictPlistRepresentation(_ text: String) {
        #expect(throws: (any Error).self) { try PropertyListConversion.plist(from: text, format: .xml) }
    }

    @Test func rejectsMalformedReservedTags() {
        let text = #"{"$maceaseType":"data","value":"not base64!"}"#
        #expect(throws: (any Error).self) {
            try PropertyListConversion.plist(from: text, format: .binary)
        }
    }

    @Test func rejectsDepthAndSizeBeforeJSONParsing() {
        let nested = String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
        #expect(throws: EngineError.invalidInput(.malformed("Conversion exceeds 64 levels"))) {
            try PropertyListConversion.plist(from: nested, format: .binary)
        }
        let oversized = String(repeating: " ", count: 8 * 1024 * 1024 + 1)
        #expect(throws: EngineError.invalidInput(.malformed("JSON exceeds 8 MiB"))) {
            try PropertyListConversion.plist(from: oversized, format: .binary)
        }
    }

    @Test func refusesExternalEntityPlists() {
        let malicious = Data(
            #"<?xml version="1.0"?><!DOCTYPE plist [<!ENTITY x SYSTEM "file:///etc/passwd">]><plist version="1.0"><string>&x;</string></plist>"#
                .utf8)
        #expect(throws: (any Error).self) {
            try PropertyListConversion.json(from: malicious, indent: "  ")
        }
    }

    @Test(arguments: [
        "<dict><key>name</key><string>first</string><key>name</key><string>second</string></dict>",
        "<array><dict><key>nested</key><dict><key>name</key><string>first</string><key>name</key><string>second</string></dict></dict></array>",
        "<dict><key/><string>first</string><key></key><string>second</string></dict>",
        "<dict><key>a&amp;b</key><string>first</string><key>a&#38;b</key><string>second</string></dict>",
        "<dict><key>na<![CDATA[m]]>e</key><string>first</string><key>name</key><string>second</string></dict>",
    ])
    func refusesDuplicateXMLKeysBeforeDecoding(_ contents: String) {
        let source = Data("<plist version=\"1.0\">\(contents)</plist>".utf8)
        #expect(throws: EngineError.invalidInput(.malformed("Duplicate JSON keys are unsupported"))) {
            _ = try PropertyListConversion.json(from: source, indent: "")
        }
    }

    @Test func refusesDuplicateUTF16XMLKeys() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-16"?>
            <plist version="1.0"><dict><key>name</key><string>first</string><key>name</key><string>second</string></dict></plist>
            """
        let source = try #require(xml.data(using: .utf16))
        #expect(throws: EngineError.invalidInput(.malformed("Duplicate JSON keys are unsupported"))) {
            _ = try PropertyListConversion.json(from: source, indent: "")
        }
    }

    @Test func allowsRepeatedKeysInSeparateXMLDictionaries() throws {
        let xml = """
            <plist version="1.0"><dict><key>name</key><string>outer</string><key>children</key><array>
            <dict><key>name</key><string>first</string></dict>
            <dict><key>name</key><string>second</string></dict>
            </array></dict></plist>
            """
        let expected = #"{"children":[{"name":"first"},{"name":"second"}],"name":"outer"}"#
        let output = try PropertyListConversion.json(from: Data(xml.utf8), indent: "")
        #expect(output.filter { !$0.isWhitespace } == expected)
    }

    @Test func refusesInternalEntityPlistsBeforeDecoding() {
        let xml =
            #"<!DOCTYPE plist [<!ENTITY name "expanded">]><plist version="1.0"><dict><key>&name;</key><string>value</string></dict></plist>"#
        #expect(throws: EngineError.invalidInput(.malformed("XML entity declarations are not supported"))) {
            _ = try PropertyListConversion.json(from: Data(xml.utf8), indent: "")
        }
    }

    @Test func boundsSharedBinaryStringExpansionBeforeSerialization() async {
        await #expect(processExitsWith: .success) {
            let sharedScalarBytes = 1024 * 1024
            let referenceCount = 3_000
            let maximumSourceBytes = 2 * sharedScalarBytes
            let maximumResidentGrowth = 64 * sharedScalarBytes
            let maximumRejectionTime = Duration.seconds(5)
            let shared = NSString(string: String(repeating: "x", count: sharedScalarBytes))
            let references = Array(repeating: shared, count: referenceCount)
            let source = try PropertyListSerialization.data(
                fromPropertyList: references, format: .binary, options: 0)
            #expect(source.count < maximumSourceBytes)

            var usage = rusage()
            try #require(getrusage(RUSAGE_SELF, &usage) == 0)
            let baselinePeak = usage.ru_maxrss
            let duration = ContinuousClock().measure {
                #expect(throws: EngineError.invalidInput(.malformed("JSON output exceeds 8 MiB"))) {
                    _ = try PropertyListConversion.json(from: source, indent: "")
                }
            }
            try #require(getrusage(RUSAGE_SELF, &usage) == 0)
            #expect(usage.ru_maxrss <= baselinePeak + maximumResidentGrowth)
            #expect(duration < maximumRejectionTime)
        }
    }

    @Test func includesFinalNewlineInJSONOutputLimit() throws {
        let maximumBytes = ConversionInput.maximumBytes
        let repeatedCount = 7
        let sharedBytes = 1024 * 1024
        let framing = "[\n" + Array(repeating: "\"\"", count: repeatedCount + 1).joined(separator: ",\n") + "\n]\n"
        let finalBytes = maximumBytes - framing.utf8.count - repeatedCount * sharedBytes
        let shared = NSString(string: String(repeating: "x", count: sharedBytes))
        let entries: [NSString] =
            Array(repeating: shared, count: repeatedCount)
            + [NSString(string: String(repeating: "y", count: finalBytes))]
        let source = try PropertyListSerialization.data(
            fromPropertyList: entries, format: .binary, options: 0)
        #expect(source.count < maximumBytes)
        let output = try PropertyListConversion.json(from: source, indent: "")
        #expect(output.utf8.count == maximumBytes)
        #expect(output.hasSuffix("\"\n]\n"))

        let oversized =
            Array(repeating: shared, count: repeatedCount)
            + [NSString(string: String(repeating: "y", count: finalBytes + 1))]
        let oversizedSource = try PropertyListSerialization.data(
            fromPropertyList: oversized, format: .binary, options: 0)
        #expect(throws: EngineError.invalidInput(.malformed("JSON output exceeds 8 MiB"))) {
            _ = try PropertyListConversion.json(from: oversizedSource, indent: "")
        }
    }

    @Test func boundsEscapedJSONOutputWhileWriting() throws {
        let controlCharacterCount = 2 * 1024 * 1024
        let controlCharacters = String(repeating: "\u{0001}", count: controlCharacterCount)
        let source = try PropertyListSerialization.data(
            fromPropertyList: [controlCharacters], format: .binary, options: 0)
        #expect(source.count < ConversionInput.maximumBytes)
        #expect(throws: EngineError.invalidInput(.malformed("JSON output exceeds 8 MiB"))) {
            _ = try PropertyListConversion.json(from: source, indent: "")
        }
    }
}
