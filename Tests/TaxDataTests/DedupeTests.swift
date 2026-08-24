import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Normalisation") struct NormalisationTests {

    @Test("vendor folding collapses case, diacritics and punctuation")
    func vendorFolding() {
        #expect(Normalisation.vendor("Guardian Health–KL") == "guardian health kl")
        #expect(Normalisation.vendor("guardian  health kl") == "guardian health kl")
        #expect(Normalisation.vendor("GUARDIAN HEALTH  KL") == "guardian health kl")
        #expect(Normalisation.vendor("  Kedai Buku Popular  ") == "kedai buku popular")
        #expect(Normalisation.vendor("Café Société") == "cafe societe")
        #expect(Normalisation.vendor("") == "")
        #expect(Normalisation.vendor("!!!") == "")
    }

    @Test("a day is resolved in Kuala Lumpur, not UTC")
    func dayIsKualaLumpur() {
        // 1_740_000_000 is 2025-02-19 21:20 UTC, which is 2025-02-20 05:20 in KL.
        // A phone abroad must agree with the phone at home about which day this was, or
        // the two produce different dedupe keys for one receipt and never converge.
        let instant = Date(timeIntervalSince1970: 1_740_000_000)
        #expect(Normalisation.day(instant) == "2025-02-20")
        #expect(Normalisation.day(nil) == "")
    }
}

@Suite("Dedupe keys") struct DedupeTests {

    @Test("the same receipt entered twice produces one key")
    func sameReceiptSameKey() async throws {
        let store = try await StoreFixture.store()
        var second = StoreFixture.entry("MEDICAL_CHECKUP", 900, vendor: "guardian  health kl")
        second.id = UUID()
        let firstID = try await store.save(
            StoreFixture.entry("MEDICAL_CHECKUP", 900, vendor: "Guardian Health–KL"))
        let secondID = try await store.save(second)

        let firstKey = try await store.dedupeKey(forEntry: firstID)
        let secondKey = try await store.dedupeKey(forEntry: secondID)
        #expect(firstKey == secondKey)
        #expect(firstKey.count == 64, "SHA-256 rendered as lowercase hex")
    }

    @Test("a different amount produces a different key")
    func amountChangesKey() async throws {
        let store = try await StoreFixture.store()
        let a = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))
        var other = StoreFixture.entry("LIFESTYLE", 1_821)
        other.id = UUID()
        let b = try await store.save(other)

        let keyA = try await store.dedupeKey(forEntry: a)
        let keyB = try await store.dedupeKey(forEntry: b)
        #expect(keyA != keyB)
    }

    @Test("a different relief code produces a different key")
    func codeChangesKey() {
        let day = "2025-02-20"
        let a = DedupeKey.entry(year: 2025, code: ReliefCode("LIFESTYLE"), amountSen: 182_000,
                                day: day, vendor: "popular", claimant: .individual, dependentID: nil)
        let b = DedupeKey.entry(year: 2025, code: ReliefCode("LIFESTYLE_SPORTS"), amountSen: 182_000,
                                day: day, vendor: "popular", claimant: .individual, dependentID: nil)
        #expect(a != b)
    }

    @Test("components cannot be smuggled across the encoding")
    func componentsCannotBeSmuggledAcrossTheEncoding() {
        // ReliefCode performs no character validation, and `ReliefEntry.reliefCodeRaw`
        // is a plain stored String that CloudKit sync writes into directly — a "|"
        // arriving in a code is reachable from a synced or corrupted record, not
        // hypothetical. Under a naive "|"-joined scheme (no length prefixes), these two
        // entirely different entries flatten to the identical string "A|1|23|D|V":
        //   ("A|1", amount: 23, day: "D",  vendor: "V")    -> "A|1" + "|23|D|V"
        //   ("A",   amount: 1,  day: "23", vendor: "D|V")  -> "A|1|23" + "|D|V"
        // A length-prefixed encoding must keep them apart.
        let a = DedupeKey.entry(year: 2025, code: ReliefCode("A|1"), amountSen: 23, day: "D",
                                vendor: "V", claimant: .individual, dependentID: nil)
        let b = DedupeKey.entry(year: 2025, code: ReliefCode("A"), amountSen: 1, day: "23",
                                vendor: "D|V", claimant: .individual, dependentID: nil)
        #expect(a != b)
    }

    @Test("a claim in a different Year of Assessment produces a different key, and both years survive reconciliation")
    func yearChangesKeyAndBothYearsSurvive() async throws {
        // Regression for the Critical from fix round 1: DedupeKey.entry did not take a
        // year, and Normalisation.day(nil) == "" while EntryDraft.spentOn defaults to
        // nil, so an undated recurring claim like SSPN logged in two different years
        // hashed identically. reconcile() then treated one year's entry as a duplicate
        // of the other's and silently soft-deleted it.
        let store = try await StoreFixture.store()
        let idA = try await store.save(StoreFixture.entry("SSPN", 3_000, year: 2024, spentOn: nil))
        let idB = try await store.save(StoreFixture.entry("SSPN", 3_000, year: 2025, spentOn: nil))

        let keyA = try await store.dedupeKey(forEntry: idA)
        let keyB = try await store.dedupeKey(forEntry: idB)
        #expect(keyA != keyB)

        _ = try await store.reconcile()
        // The regression collapsed one year's row into the other; asserting the
        // surviving count per year, not just key inequality, is what actually catches
        // that — two different keys that both happened to size their group at 1 would
        // pass a bare inequality check and still miss a collapse elsewhere.
        #expect(try await store.entryDrafts(forYear: 2024).count == 1)
        #expect(try await store.entryDrafts(forYear: 2025).count == 1)
    }

    @Test("a different dependentID produces a different key")
    func dependentIDChangesKey() {
        let day = "2025-02-20"
        let childOne = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let childTwo = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        // Same code, amount, day and vendor — only which child the claim is for differs.
        // Without dependentID in the key, two children's identical claims in one year
        // would collapse into a single claim, silently discarding one child's relief.
        let a = DedupeKey.entry(year: 2025, code: ReliefCode("CHILD_MEDICAL"), amountSen: 150_000,
                                day: day, vendor: "klinik", claimant: .child, dependentID: childOne)
        let b = DedupeKey.entry(year: 2025, code: ReliefCode("CHILD_MEDICAL"), amountSen: 150_000,
                                day: day, vendor: "klinik", claimant: .child, dependentID: childTwo)
        #expect(a != b)
    }

    @Test("a different claimant produces a different key")
    func claimantChangesKey() {
        let day = "2025-02-20"
        let a = DedupeKey.entry(year: 2025, code: ReliefCode("MEDICAL_SERIOUS"), amountSen: 650_000,
                                day: day, vendor: "hospital", claimant: .individual, dependentID: nil)
        let b = DedupeKey.entry(year: 2025, code: ReliefCode("MEDICAL_SERIOUS"), amountSen: 650_000,
                                day: day, vendor: "hospital", claimant: .spouse, dependentID: nil)
        #expect(a != b)
    }

    @Test("editing an entry recomputes its key")
    func editRecomputesKey() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))
        let before = try await store.dedupeKey(forEntry: id)

        var edited = try #require(try await store.entryDrafts(forYear: 2025).first)
        edited.amount = Money(ringgit: 2_000)
        _ = try await store.save(edited)

        let after = try await store.dedupeKey(forEntry: id)
        #expect(before != after, "a stale key would hide a duplicate the edit just created")
    }

    @Test("content hashing is stable and sensitive")
    func contentHash() {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        #expect(DedupeKey.content(bytes) == DedupeKey.content(bytes))
        #expect(DedupeKey.content(bytes) != DedupeKey.content(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x11])))
        #expect(DedupeKey.content(bytes).count == 64)
    }

    @Test("needsDocument is true when a required document is absent")
    func needsDocumentReflectsTheRulebook() async throws {
        let store = try await StoreFixture.store()
        // LIFE_INSURANCE requires an insurance statement in the YA2025 rulebook and this
        // entry has no documents attached at all.
        let id = try await store.save(StoreFixture.entry("LIFE_INSURANCE", 2_100))
        let draft = try #require(try await store.entryDrafts(forYear: 2025).first { $0.id == id })
        #expect(draft.needsDocument == true)
    }

    @Test("an entry in a year with no shipped rulebook is not flagged")
    func unknownYearDoesNotFlag() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(StoreFixture.entry("LIFE_INSURANCE", 2_100, year: 2019))
        let draft = try #require(try await store.entryDrafts(forYear: 2019).first { $0.id == id })
        // Browsing a year whose rules the app does not ship must show the entries, not
        // an amber warning the app has no basis for.
        #expect(draft.needsDocument == false)
    }
}
