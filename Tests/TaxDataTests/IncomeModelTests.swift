import Testing
import Foundation
import SwiftData
import TaxKit
@testable import TaxData

@Suite("Income models") struct IncomeModelTests {

    @Test("a fresh source is unanswered rather than assumed")
    func freshSourceIsUnanswered() {
        let source = IncomeSource(name: "Main job")
        #expect(source.name == "Main job")
        #expect(source.kind == .employment)
        #expect(source.endedOn == nil)
        #expect(source.deletedAt == nil)
        #expect(source.updatedAt == .distantPast)
        // nil, not false. A second employment deducts EPF and SOCSO; occasional 4(f)
        // income does not; and employment does not guarantee it either. Storing false for
        // a question nobody asked is how an app silently refuses a relief.
        #expect(source.deductsEPF == nil)
        #expect(source.deductsSOCSO == nil)
    }

    @Test("kind round-trips through raw storage and degrades safely")
    func kindRoundTrips() {
        let source = IncomeSource(name: "Design freelance")
        source.kind = .occasional
        #expect(source.kindRaw == "occasional")
        #expect(source.kind == .occasional)

        // A value from a future build must not trap; it reads as `other`, which is the
        // kind that warns rather than the kind that stays silent.
        source.kindRaw = "cryptoMining"
        #expect(source.kind == .other)
    }

    @Test("a record round-trips its amount and shape")
    func recordRoundTrips() {
        let record = IncomeRecord()
        record.shape = .recurring
        record.amount = Money(ringgit: 8_000)
        #expect(record.shapeRaw == "recurring")
        #expect(record.amountSen == 800_000)
        #expect(record.amount == Money(ringgit: 8_000))

        record.shape = .oneOff
        #expect(record.shape == .oneOff)
    }

    @Test("records belong to a source and the source lists them")
    func sourceRecordInverse() throws {
        let container = try TaxContainer.make(.inMemory)
        let context = ModelContext(container)

        let source = IncomeSource(name: "Main job")
        let january = IncomeRecord()
        january.shape = .recurring
        january.amount = Money(ringgit: 8_000)
        january.source = source
        context.insert(source)
        context.insert(january)
        try context.save()

        #expect(source.records?.count == 1)
        #expect(source.records?.first?.amount == Money(ringgit: 8_000))
        #expect(january.source?.name == "Main job")
    }

    @Test("liveRecords excludes soft-deleted ones")
    func liveRecordsFilter() throws {
        let container = try TaxContainer.make(.inMemory)
        let context = ModelContext(container)
        let source = IncomeSource(name: "Main job")
        let kept = IncomeRecord(); kept.source = source
        let removed = IncomeRecord(); removed.source = source
        removed.deletedAt = Date(timeIntervalSince1970: 1)
        for object in [source] { context.insert(object) }
        for object in [kept, removed] { context.insert(object) }
        try context.save()

        // A deleted raise that still counted would silently inflate the year's income.
        #expect(source.liveRecords.count == 1)
        #expect(source.liveRecords.first?.id == kept.id)
    }

    @Test("both new models are CloudKit-mirroring-safe")
    func mirroringSafe() {
        let problems = SchemaInvariants.violations(in: Schema(SchemaV2.models))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("SchemaV1 now lists nine models")
    func schemaIsComplete() {
        let names = Set(SchemaV1.models.map { String(describing: $0) })
        #expect(names == ["TaxYear", "Dependent", "ReliefEntry", "Document", "DocumentFile",
                          "ChatMessage", "UserPreferences", "IncomeSource", "IncomeRecord"])
    }
}
