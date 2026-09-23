import Testing
import Foundation
import TaxKit
import TaxData
import TaxCapture
@testable import TaxPresentation

/// Receipt readings built by hand: the view model's job is what it does with a reading,
/// not how one is made, and Vision has no place in these tests.
@MainActor enum ReceiptFixture {

    static func files() throws -> DocumentFileStore {
        try DocumentFileStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "relio-receipts-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { ReceiptDate.noon(y, m, d)! }

    static func reading(bytes: String = "receipt-one",
                        total: Money? = Money(sen: 7_190), totalConfidence: Double = 0.95,
                        date: Date? = day(2025, 3, 7), dateConfidence: Double = 0.5,
                        vendor: String? = "MPH BOOKSTORES SDN BHD", vendorConfidence: Double = 0.6,
                        ocrText: String? = "MPH BOOKSTORES SDN BHD\nTOTAL RM 71.90",
                        eInvoiceUUID: String? = nil,
                        suggested: [ReliefCode] = [.lifestyle]) -> ReceiptReading {
        ReceiptReading(
            document: NormalisedDocument(data: Data(bytes.utf8), uti: "public.jpeg",
                                         fileExtension: "jpg", thumbnail: Data("thumb".utf8),
                                         pageImages: [], textSource: .pageImages),
            ocrText: ocrText,
            eInvoiceUUID: eInvoiceUUID,
            total: total.map { Reading(value: $0, confidence: totalConfidence, source: .label("TOTAL")) },
            date: date.map { Reading(value: $0, confidence: dateConfidence, source: .label("DATE")) },
            vendor: vendor.map { Reading(value: $0, confidence: vendorConfidence, source: .heuristic) },
            suggestedReliefs: suggested)
    }

    /// A new-entry editor, *not* loaded: prefill comes first.
    static func newEditor(_ store: TaxStore, year: Int = 2025) async -> EntryEditorViewModel {
        let context = PresentationFixture.context(store, year: year)
        await context.load()
        return EntryEditorViewModel(context: context, store: store, editing: nil)
    }

    static func fileExists(_ files: DocumentFileStore, bytes: String) -> Bool {
        let url = files.url(forHash: DocumentFileStore.hash(Data(bytes.utf8)), extension: "jpg")
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Scans, picks Lifestyle and saves — the whole scan-first flow.
    static func scanAndSave(_ store: TaxStore, files: DocumentFileStore,
                            reading: ReceiptReading = reading()) async throws -> EntryEditorViewModel {
        let model = await newEditor(store)
        #expect(await model.prefill(from: reading, files: files))
        await model.load()
        model.selectedCode = .lifestyle
        #expect(await model.save())
        return model
    }
}

@Suite("Entry editor: a receipt starts the entry") @MainActor struct ReceiptEditorTests {

    @Test("the fields are prefilled, the relief is left for the user, and the file waits")
    func prefillsTheFields() async throws {
        let store = try await PresentationFixture.store()
        let files = try ReceiptFixture.files()
        let model = await ReceiptFixture.newEditor(store)

        #expect(await model.prefill(from: ReceiptFixture.reading(), files: files))
        await model.load()

        #expect(model.amountText == "71.90")
        #expect(model.vendor == "MPH BOOKSTORES SDN BHD")
        #expect(model.spentOn == ReceiptFixture.day(2025, 3, 7))
        #expect(model.unconfirmed == [.date, .vendor], "the total was read at 0.95")
        #expect(model.selectedCode == nil, "candidates are offered, never chosen")
        #expect(model.suggestedReliefs == [.lifestyle])
        #expect(model.hasPendingReceipt)
        #expect(model.pendingReceiptThumbnail == Data("thumb".utf8))
        #expect(ReceiptFixture.fileExists(files, bytes: "receipt-one"))
        #expect(try await store.entryDrafts(forYear: 2025).isEmpty, "nothing saved yet")
    }

    @Test("editing a field, or confirming it, clears its unconfirmed mark")
    func editingClearsUnconfirmed() async throws {
        let store = try await PresentationFixture.store()
        let model = await ReceiptFixture.newEditor(store)
        _ = await model.prefill(from: ReceiptFixture.reading(), files: try ReceiptFixture.files())

        model.vendor = "MPH Mid Valley"
        #expect(model.unconfirmed == [.date])
        model.confirm(.date)
        #expect(model.unconfirmed.isEmpty)
    }

    @Test("what the receipt did not say stays blank, and a blank read is said so")
    func missingFieldsStayBlank() async throws {
        let store = try await PresentationFixture.store()
        let model = await ReceiptFixture.newEditor(store)
        let blank = ReceiptFixture.reading(total: nil, date: nil, vendor: nil, ocrText: nil,
                                           suggested: [])
        #expect(await model.prefill(from: blank, files: try ReceiptFixture.files()))
        #expect(model.amountText == "")
        #expect(model.spentOn == nil)
        #expect(model.vendor == "")
        #expect(model.unconfirmed.isEmpty)
        #expect(model.couldNotReadReceipt)
        #expect(model.hasPendingReceipt, "the file is still attached on save")
    }

    @Test("saving saves the entry, then attaches the receipt with what was read")
    func saveAttachesTheReceipt() async throws {
        let store = try await PresentationFixture.store()
        let model = try await ReceiptFixture.scanAndSave(store, files: try ReceiptFixture.files())

        let entry = try #require(try await store.entryDrafts(forYear: 2025).first)
        #expect(entry.id == model.newEntryID)
        #expect(entry.amount == Money(sen: 7_190))
        #expect(entry.needsDocument == false)
        let document = try #require(try await store.documentDrafts(forEntry: entry.id).first)
        #expect(document.kind == .officialReceipt)
        #expect(document.contentHash == DocumentFileStore.hash(Data("receipt-one".utf8)))
        #expect(document.ocrText == "MPH BOOKSTORES SDN BHD\nTOTAL RM 71.90")
        #expect(document.total == Money(sen: 7_190))
        #expect(model.hasPendingReceipt == false)
    }

    @Test("an e-invoice is badged and still attached as the kind the relief asks for")
    func eInvoiceKeepsTheRequiredKind() async throws {
        let store = try await PresentationFixture.store()
        let reading = ReceiptFixture.reading(eInvoiceUUID: "F9D425P6DS7D8IU")
        let model = try await ReceiptFixture.scanAndSave(store, files: try ReceiptFixture.files(),
                                                         reading: reading)
        #expect(model.isEInvoice)
        let document = try #require(try await store.documentDrafts(forEntry: model.newEntryID).first)
        #expect(document.kind == .officialReceipt)
        #expect(document.eInvoiceUUID == "F9D425P6DS7D8IU")
    }

    @Test("saving twice is one entry, not two")
    func savingTwiceIsOneEntry() async throws {
        let store = try await PresentationFixture.store()
        let model = try await ReceiptFixture.scanAndSave(store, files: try ReceiptFixture.files())
        model.note = "Books for the course"
        #expect(await model.save())
        #expect(try await store.entryDrafts(forYear: 2025).count == 1)
        #expect(try await store.documentDrafts(forEntry: model.newEntryID).count == 1)
    }

    @Test("cancelling deletes a file nothing else uses")
    func cancelDeletesAnUnusedFile() async throws {
        let store = try await PresentationFixture.store()
        let files = try ReceiptFixture.files()
        let model = await ReceiptFixture.newEditor(store)
        _ = await model.prefill(from: ReceiptFixture.reading(), files: files)

        await model.discardPendingReceipt()
        #expect(ReceiptFixture.fileExists(files, bytes: "receipt-one") == false)
        #expect(model.hasPendingReceipt == false)
    }

    /// Review focus 2. The file store is content-addressed: scanning a receipt already on
    /// a claim writes the *same* file. Deleting it on cancel would take the saved claim's
    /// receipt with it.
    @Test("cancelling keeps a file another claim already uses")
    func cancelKeepsAFileAnotherClaimUses() async throws {
        let store = try await PresentationFixture.store()
        let files = try ReceiptFixture.files()
        _ = try await ReceiptFixture.scanAndSave(store, files: files)

        let again = await ReceiptFixture.newEditor(store)
        _ = await again.prefill(from: ReceiptFixture.reading(), files: files)
        #expect(again.receiptDuplicateWarning
                == "This receipt already supports your RM 71.90 lifestyle claim from 7 Mar.")

        await again.discardPendingReceipt()
        #expect(ReceiptFixture.fileExists(files, bytes: "receipt-one"))
    }

    /// Review focus 3. The editor has no year field: a receipt from December 2024 scanned
    /// with YA 2025 open is saved into 2025 unless the user notices.
    @Test("a receipt from another year is flagged, and the flag follows the date")
    func receiptFromAnotherYearIsFlagged() async throws {
        let store = try await PresentationFixture.store()
        let model = await ReceiptFixture.newEditor(store)
        _ = await model.prefill(from: ReceiptFixture.reading(date: ReceiptFixture.day(2024, 12, 28)),
                                files: try ReceiptFixture.files())
        #expect(model.receiptYearMismatch
                == "This receipt is dated 2024. It will count towards YA 2025 — switch year first if that is wrong.")

        model.spentOn = ReceiptFixture.day(2025, 1, 2)
        #expect(model.receiptYearMismatch == nil)
    }

    @Test("an entry typed by hand is never flagged for its year")
    func noReceiptNoYearFlag() async throws {
        let store = try await PresentationFixture.store()
        let model = await ReceiptFixture.newEditor(store)
        model.spentOn = ReceiptFixture.day(2024, 12, 28)
        #expect(model.receiptYearMismatch == nil)
    }

    @Test("the file cannot be written: nothing is prefilled and the caller is told")
    func fileWriteFailureRefusesPrefill() async throws {
        let store = try await PresentationFixture.store()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relio-gone-\(UUID().uuidString)", directoryHint: .isDirectory)
        let files = try DocumentFileStore(directory: directory)
        try FileManager.default.removeItem(at: directory)

        let model = await ReceiptFixture.newEditor(store)
        #expect(await model.prefill(from: ReceiptFixture.reading(), files: files) == false)
        #expect(model.amountText == "")
        #expect(model.hasPendingReceipt == false)
    }

    @Test("an editor opened on a saved entry is not prefilled")
    func editingIsNotPrefilled() async throws {
        let store = try await PresentationFixture.store()
        let id = try await store.save(EntryDraft(year: 2025, code: .lifestyle,
                                                 amount: Money(ringgit: 300)))
        let context = PresentationFixture.context(store, year: 2025)
        await context.load()
        let model = EntryEditorViewModel(context: context, store: store, editing: id)
        #expect(await model.prefill(from: ReceiptFixture.reading(),
                                    files: try ReceiptFixture.files()) == false)
    }
}
