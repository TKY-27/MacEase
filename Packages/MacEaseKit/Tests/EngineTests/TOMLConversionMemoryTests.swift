import Darwin
import Foundation
import Testing

@testable import Engine

@Suite struct TOMLConversionMemoryTests {
    private let payloadBytes = 512 * 1024
    private let warmupCount = 8
    private let conversionCount = 40
    private let maximumGrowth: UInt64 = 16 * 1024 * 1024

    @Test func repeatedParsingReleasesTables() async {
        await #expect(processExitsWith: .success) {
            let fixture = TOMLConversionMemoryTests()
            let toml = "payload = \"" + String(repeating: "x", count: fixture.payloadBytes) + "\""
            try fixture.expectBoundedGrowth {
                let result = try TOMLConversion.json(fromTOML: toml)
                guard case .object(let members) = result, members.count == 1,
                    case .string(let payload) = members[0].value
                else {
                    Issue.record("The parsed payload is missing")
                    return
                }
                #expect(payload.utf8.count == fixture.payloadBytes)
            }
        }
    }

    @Test func repeatedWritingReleasesTables() async {
        await #expect(processExitsWith: .success) {
            let fixture = TOMLConversionMemoryTests()
            let json = "{\"payload\":\"" + String(repeating: "x", count: fixture.payloadBytes) + "\"}"
            try fixture.expectBoundedGrowth {
                let result = try TOMLConversion.toml(fromJSON: json)
                #expect(result.utf8.count >= fixture.payloadBytes)
            }
        }
    }

    @Test func rejectedConversionsReleasePartialTrees() async {
        await #expect(processExitsWith: .success) {
            let fixture = TOMLConversionMemoryTests()
            let payload = String(repeating: "x", count: fixture.payloadBytes)
            let invalidSyntax = "payload = \"\(payload)\"\nbroken ="
            let nonfinite = "payload = \"\(payload)\"\nreal = inf"
            let null = "{\"payload\":\"\(payload)\",\"missing\":null}"
            try fixture.expectBoundedGrowth {
                #expect(throws: EngineError.self) { try TOMLConversion.json(fromTOML: invalidSyntax) }
                #expect(throws: EngineError.invalidInput(.malformed("TOML number at $.real is not finite"))) {
                    try TOMLConversion.json(fromTOML: nonfinite)
                }
                #expect(throws: EngineError.invalidInput(.malformed("JSON null at $.missing has no TOML value"))) {
                    try TOMLConversion.toml(fromJSON: null)
                }
            }
        }
    }

    private func expectBoundedGrowth(_ conversion: () throws -> Void) throws {
        for _ in 0..<warmupCount { try autoreleasepool(invoking: conversion) }
        let baseline = try residentBytes()
        for _ in 0..<conversionCount { try autoreleasepool(invoking: conversion) }
        let resident = try residentBytes()
        #expect(resident <= baseline + maximumGrowth)
    }

    private func residentBytes() throws -> UInt64 {
        var statistics = mach_task_basic_info()
        let capacity = MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { integers in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), integers, &count)
            }
        }
        try #require(status == KERN_SUCCESS)
        return statistics.resident_size
    }
}
