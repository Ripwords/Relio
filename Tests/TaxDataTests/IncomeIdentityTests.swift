import Testing
import Foundation
import SwiftData
import TaxKit
@testable import TaxData

@Suite("Income identity") struct IncomeIdentityTests {

    @Test("the seeded employment identity is a fixed, pinned UUID")
    func primaryEmploymentIdentityIsPinned() {
        // Changing this value strands every already-seeded row on every device running an
        // older build: the two identities no longer match, so nothing collapses them and
        // the user's income doubles — the exact failure the well-known id exists to stop.
        #expect(WellKnownID.primaryEmployment
                == UUID(uuidString: "6B1F0C2E-9A47-4D31-8E55-0F2A7C4D9B10"))
    }

    @Test("the opening rate identity is a pure function of its source and year")
    func openingRateIsDerived() {
        let source = WellKnownID.primaryEmployment
        let january = IncomeStoreTests.date(2025, 1, 1)

        #expect(WellKnownID.openingRate(forSource: source, effectiveFrom: january)
                == WellKnownID.openingRate(forSource: source, effectiveFrom: january))
        // Onboarding a different year is a different rate, which should chain onto the
        // timeline rather than collide with the one already there.
        #expect(WellKnownID.openingRate(forSource: source, effectiveFrom: january)
                != WellKnownID.openingRate(forSource: source,
                                           effectiveFrom: IncomeStoreTests.date(2024, 1, 1)))
        #expect(WellKnownID.openingRate(forSource: source, effectiveFrom: january)
                != WellKnownID.openingRate(forSource: UUID(), effectiveFrom: january))
    }

    @Test("two devices seeding different start dates in one year agree on the rate identity")
    func openingRateIgnoresTheDayWithinAYear() {
        let source = WellKnownID.primaryEmployment
        // Nothing coordinates the two phones, and each user picked their own start date.
        // Only the year participates, so both write one row and the first answer stands.
        #expect(WellKnownID.openingRate(forSource: source,
                                        effectiveFrom: IncomeStoreTests.date(2025, 1, 1))
                == WellKnownID.openingRate(forSource: source,
                                           effectiveFrom: IncomeStoreTests.date(2025, 7, 14)))
    }

    @Test("the derived rate identity is a well-formed version 4 UUID")
    func openingRateIsWellFormed() {
        let derived = WellKnownID.openingRate(forSource: WellKnownID.primaryEmployment,
                                              effectiveFrom: IncomeStoreTests.date(2025, 1, 1))
        // SwiftData and CloudKit both round-trip these through their own UUID types, so a
        // hand-rolled value that is not RFC 4122 shaped is a risk with no upside.
        #expect(derived.uuid.6 & 0xF0 == 0x40)
        #expect(derived.uuid.8 & 0xC0 == 0x80)
    }

    @Test("an unanswered deduction hashes differently from a confirmed no")
    func unansweredIsNotFalse() {
        func key(deductsEPF: Bool?) -> String {
            DedupeKey.incomeSourceContent(name: "Main job", kindRaw: "employment",
                                          deductsEPF: deductsEPF, deductsSOCSO: nil,
                                          endedOn: nil)
        }
        // `nil` is "not asked yet" and `false` is "confirmed no deductions". Collapsing
        // them here would let the sweep call two rows indistinguishable when one of them
        // carries an answer the user gave.
        #expect(key(deductsEPF: nil) != key(deductsEPF: false))
        #expect(key(deductsEPF: false) != key(deductsEPF: true))
    }

    @Test("an end date changes the source content key")
    func endDateParticipates() {
        let open = DedupeKey.incomeSourceContent(name: "Main job", kindRaw: "employment",
                                                 deductsEPF: nil, deductsSOCSO: nil,
                                                 endedOn: nil)
        let ended = DedupeKey.incomeSourceContent(name: "Main job", kindRaw: "employment",
                                                  deductsEPF: nil, deductsSOCSO: nil,
                                                  endedOn: IncomeStoreTests.date(2025, 9, 30))
        #expect(open != ended)
    }

    @Test("income content components cannot be smuggled across the encoding")
    func componentsCannotBeSmuggled() {
        // The same collision `componentsCannotBeSmuggledAcrossTheEncoding` pins for
        // entries: `name` and `kindRaw` are plain stored strings CloudKit writes into, so
        // a delimiter join would let one row's content masquerade as another's.
        #expect(DedupeKey.incomeSourceContent(name: "Main|job", kindRaw: "employment",
                                              deductsEPF: nil, deductsSOCSO: nil, endedOn: nil)
                != DedupeKey.incomeSourceContent(name: "Main", kindRaw: "job|employment",
                                                 deductsEPF: nil, deductsSOCSO: nil, endedOn: nil))
        #expect(DedupeKey.incomeRecordContent(shapeRaw: "recurring|x", amountSen: 1,
                                              effectiveFrom: .distantPast, note: "")
                != DedupeKey.incomeRecordContent(shapeRaw: "recurring", amountSen: 1,
                                                 effectiveFrom: .distantPast, note: "x|"))
    }

    @Test("a source and a record cannot collide across the identity encoding")
    func sourcesAndRecordsDoNotCollide() {
        // Both keys are computed over the same encoder, so the tag that separates their
        // namespaces is the only thing keeping a source's content key out of the record
        // pass's comparisons.
        #expect(DedupeKey.incomeSourceContent(name: "recurring", kindRaw: "0",
                                              deductsEPF: nil, deductsSOCSO: nil, endedOn: nil)
                != DedupeKey.incomeRecordContent(shapeRaw: "recurring", amountSen: 0,
                                                 effectiveFrom: .distantPast, note: ""))
    }
}
