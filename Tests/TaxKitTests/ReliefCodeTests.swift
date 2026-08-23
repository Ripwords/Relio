import Testing
import Foundation
@testable import TaxKit

@Suite("ReliefCode") struct ReliefCodeTests {

    @Test("wraps a raw string without altering it")
    func wrapsRawValue() {
        #expect(ReliefCode("LIFESTYLE").rawValue == "LIFESTYLE")
        #expect(ReliefCode(rawValue: "LIFESTYLE") == ReliefCode("LIFESTYLE"))
    }

    @Test("named constants match their raw values")
    func namedConstants() {
        #expect(ReliefCode.lifestyle.rawValue == "LIFESTYLE")
        #expect(ReliefCode.medicalSerious.rawValue == "MEDICAL_SERIOUS")
    }

    @Test("encodes as a bare string, not an object")
    func encodesAsString() throws {
        let data = try JSONEncoder().encode(ReliefCode.lifestyle)
        #expect(String(data: data, encoding: .utf8) == "\"LIFESTYLE\"")
        #expect(try JSONDecoder().decode(ReliefCode.self, from: data) == .lifestyle)
    }

    @Test("allGenerated lists every constant exactly once")
    func allGeneratedIsUnique() {
        let raws = ReliefCode.allGenerated.map(\.rawValue)
        #expect(raws.count == Set(raws).count)
        #expect(raws.contains("LIFESTYLE"))
    }
}
