import Testing
import Foundation
import TaxKit
@testable import TaxData

/// `Document` and `DocumentFile` have been modelled since the first plan, `ReliefEntry`
/// reads `documentKinds` off them, and `refreshDerivedFields` recomputes `needsDocument`
/// from that — every part of the loop existed except the one that attaches a document to
/// an entry. So the app could say a claim was missing a receipt and nothing could ever
/// stop it saying so.
@Suite("Attaching a document") struct DocumentAttachmentTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return cal.date(from: c)!
    }

    /// LIFESTYLE requires an official receipt in every shipped rulebook, which is what
    /// makes it the useful fixture here.
    static func seededEntry(_ store: TaxStore) async throws -> UUID {
        try await store.save(EntryDraft(year: 2025,
                                        code: .lifestyle,
                                        amount: Money(ringgit: 300),
                                        vendor: "Kinokuniya",
                                        spentOn: date(2025, 2, 11)))
    }

    static func receipt(hash: String = "abc123") -> DocumentDraft {
        DocumentDraft(kind: .officialReceipt,
                      vendor: "Kinokuniya",
                      documentDate: date(2025, 2, 11),
                      total: Money(ringgit: 300),
                      byteCount: 48_000,
                      contentHash: hash,
                      uti: "public.jpeg")
    }

    @Test("attaching the document a relief requires clears the flag")
    func attachingClearsNeedsDocument() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.seededEntry(store)
        #expect(try await store.entryDrafts(forYear: 2025).first?.needsDocument == true)

        _ = try await store.attach(Self.receipt(), toEntry: entryID)

        let entry = try #require(try await store.entryDrafts(forYear: 2025).first)
        #expect(entry.needsDocument == false)
        #expect(entry.documentKinds == [.officialReceipt])
    }

    /// A medical certificate is a document, and it is not the document LHDN asks for here.
    /// Clearing the flag for any attachment at all would let a user file a claim believing
    /// it was supported when it is not.
    @Test("attaching the wrong kind does not satisfy the requirement")
    func wrongKindDoesNotSatisfy() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.seededEntry(store)

        var wrong = Self.receipt()
        wrong.kind = .medicalCertificate
        _ = try await store.attach(wrong, toEntry: entryID)

        #expect(try await store.entryDrafts(forYear: 2025).first?.needsDocument == true)
    }

    /// The model's own doc comment: the content hash "catches the same photo imported
    /// twice". Two attachments of one image is one document, not two rows claiming the
    /// same receipt.
    @Test("the same file attached twice is one document")
    func sameFileAttachesOnce() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.seededEntry(store)

        let first = try await store.attach(Self.receipt(hash: "same"), toEntry: entryID)
        let second = try await store.attach(Self.receipt(hash: "same"), toEntry: entryID)

        #expect(first == second)
        #expect(try await store.documentDrafts(forEntry: entryID).count == 1)
    }

    /// A different photo of the same receipt is a different document — the hash is the
    /// only thing that says otherwise, and it must not over-match.
    @Test("a different file is a second document")
    func differentFileAttachesSeparately() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.seededEntry(store)

        _ = try await store.attach(Self.receipt(hash: "one"), toEntry: entryID)
        _ = try await store.attach(Self.receipt(hash: "two"), toEntry: entryID)
        #expect(try await store.documentDrafts(forEntry: entryID).count == 2)
    }

    /// Spec §11.6 again: removing a document is destructive, and it puts the claim back
    /// to unsupported, so it has to be reversible.
    @Test("removing a document puts the requirement back, and undo restores it")
    func removingIsUndoable() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.seededEntry(store)
        let documentID = try await store.attach(Self.receipt(), toEntry: entryID)
        #expect(try await store.entryDrafts(forYear: 2025).first?.needsDocument == false)

        try await store.softDeleteDocument(id: documentID)
        #expect(try await store.entryDrafts(forYear: 2025).first?.needsDocument == true)
        #expect(try await store.documentDrafts(forEntry: entryID).isEmpty)

        try await store.restoreDocument(id: documentID)
        #expect(try await store.entryDrafts(forYear: 2025).first?.needsDocument == false)
        #expect(try await store.documentDrafts(forEntry: entryID).count == 1)
    }

    /// An entry deleted on another device, most likely. Attaching to nothing has to be
    /// refused rather than quietly creating a document no screen can ever reach.
    @Test("attaching to an entry that does not exist is refused, not orphaned")
    func attachingToAnUnknownEntryIsRefused() async throws {
        let store = try await StoreFixture.store()
        _ = try await Self.seededEntry(store)
        let ghost = UUID()

        var refused = false
        do {
            _ = try await store.attach(Self.receipt(), toEntry: ghost)
        } catch DocumentAttachmentError.noSuchEntry {
            refused = true
        }
        #expect(refused)
        #expect(try await store.documentDrafts(forEntry: ghost).isEmpty)
    }
}

/// Spec §3 "Changes to existing code" and §5 "Duplicate warning". The store already
/// had the columns — `Document.ocrText` and `eInvoiceUUID` since Plan 2 — and nothing
/// ever filled them.
@Suite("Documents: what was read, and what else it supports") struct DocumentReadingStoreTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        DocumentAttachmentTests.date(y, m, d)
    }

    static func entry(_ store: TaxStore, ringgit: Decimal = 230,
                      spentOn: Date? = date(2025, 3, 3)) async throws -> UUID {
        try await store.save(EntryDraft(year: 2025, code: .lifestyle,
                                        amount: Money(ringgit: ringgit),
                                        vendor: "MPH", spentOn: spentOn))
    }

    static func receipt(hash: String, uuid: String? = nil) -> DocumentDraft {
        DocumentDraft(kind: .officialReceipt, vendor: "MPH BOOKSTORES SDN BHD",
                      documentDate: date(2025, 3, 3), total: Money(ringgit: 230),
                      byteCount: 48_000, contentHash: hash, uti: "public.jpeg",
                      ocrText: "MPH BOOKSTORES SDN BHD\nTOTAL RM 230.00",
                      eInvoiceUUID: uuid)
    }

    @Test("the receipt's text and e-invoice ID are recorded and read back")
    func readingIsRecorded() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.entry(store)
        _ = try await store.attach(Self.receipt(hash: "h1", uuid: "F9D425P6DS7D8IU"),
                                   toEntry: entryID)
        let document = try #require(try await store.documentDrafts(forEntry: entryID).first)
        #expect(document.ocrText == "MPH BOOKSTORES SDN BHD\nTOTAL RM 230.00")
        #expect(document.eInvoiceUUID == "F9D425P6DS7D8IU")
        #expect(document.kind == .officialReceipt, "a QR never changes the kind")
    }

    /// The same e-invoice downloaded twice as two PDFs: different bytes, one document.
    @Test("the same e-invoice attached twice to one entry is one document")
    func sameEInvoiceAttachesOnce() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.entry(store)
        let first = try await store.attach(Self.receipt(hash: "pdf-a", uuid: "UUID0000001"),
                                           toEntry: entryID)
        let second = try await store.attach(Self.receipt(hash: "pdf-b", uuid: "UUID0000001"),
                                            toEntry: entryID)
        #expect(first == second)
        #expect(try await store.documentDrafts(forEntry: entryID).count == 1)
    }

    @Test("two receipts with no e-invoice ID are not merged on it")
    func nilUUIDsDoNotMatch() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.entry(store)
        _ = try await store.attach(Self.receipt(hash: "a"), toEntry: entryID)
        _ = try await store.attach(Self.receipt(hash: "b"), toEntry: entryID)
        #expect(try await store.documentDrafts(forEntry: entryID).count == 2)
    }

    @Test("a file already on a claim is found by its hash, except on the entry asking")
    func supportedByHash() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.entry(store)
        _ = try await store.attach(Self.receipt(hash: "h1"), toEntry: entryID)

        let claims = try await store.claimsSupported(byHash: "h1", orEInvoiceUUID: nil,
                                                     excludingEntry: nil)
        #expect(claims == [SupportedClaim(entryID: entryID, code: .lifestyle,
                                          amount: Money(ringgit: 230),
                                          spentOn: Self.date(2025, 3, 3))])
        #expect(try await store.claimsSupported(byHash: "h1", orEInvoiceUUID: nil,
                                                excludingEntry: entryID).isEmpty)
        #expect(try await store.claimsSupported(byHash: "other", orEInvoiceUUID: nil,
                                                excludingEntry: nil).isEmpty)
    }

    @Test("a different file of the same e-invoice is found by its ID")
    func supportedByEInvoice() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.entry(store)
        _ = try await store.attach(Self.receipt(hash: "photo", uuid: "UUID0000001"),
                                   toEntry: entryID)
        let claims = try await store.claimsSupported(byHash: "pdf",
                                                     orEInvoiceUUID: "UUID0000001",
                                                     excludingEntry: nil)
        #expect(claims.map(\.entryID) == [entryID])
    }

    @Test("one entry is reported once, and entries come earliest first")
    func oneRowPerEntry() async throws {
        let store = try await StoreFixture.store()
        let later = try await Self.entry(store, ringgit: 100, spentOn: Self.date(2025, 5, 1))
        let earlier = try await Self.entry(store, ringgit: 130, spentOn: Self.date(2025, 3, 3))
        // `later` matches twice — by hash and by e-invoice ID — and is listed once.
        _ = try await store.attach(Self.receipt(hash: "h1", uuid: "UUID0000001"), toEntry: later)
        _ = try await store.attach(Self.receipt(hash: "h1"), toEntry: earlier)

        let claims = try await store.claimsSupported(byHash: "h1", orEInvoiceUUID: "UUID0000001",
                                                     excludingEntry: nil)
        #expect(claims.map(\.entryID) == [earlier, later])
    }

    /// Review focus 4. A receipt the user took off a claim, or a claim they deleted, no
    /// longer supports anything — warning about it would be warning about nothing.
    @Test("removed documents and deleted entries support nothing")
    func removedDocumentsSupportNothing() async throws {
        let store = try await StoreFixture.store()
        let kept = try await Self.entry(store)
        let documentID = try await store.attach(Self.receipt(hash: "h1"), toEntry: kept)
        try await store.softDeleteDocument(id: documentID)
        #expect(try await store.claimsSupported(byHash: "h1", orEInvoiceUUID: nil,
                                                excludingEntry: nil).isEmpty)

        let deleted = try await Self.entry(store, ringgit: 99)
        _ = try await store.attach(Self.receipt(hash: "h2", uuid: "UUID0000002"), toEntry: deleted)
        try await store.softDeleteEntry(id: deleted)
        #expect(try await store.claimsSupported(byHash: "h2", orEInvoiceUUID: "UUID0000002",
                                                excludingEntry: nil).isEmpty)
    }

    @Test("an empty hash matches nothing, even documents with an empty hash")
    func emptyHashMatchesNothing() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.entry(store)
        _ = try await store.attach(Self.receipt(hash: ""), toEntry: entryID)
        #expect(try await store.claimsSupported(byHash: "", orEInvoiceUUID: nil,
                                                excludingEntry: nil).isEmpty)
    }

    /// Cancelling a scan deletes the file it wrote unless something points at it. A
    /// soft-deleted document still does: undo would bring it back to a missing file.
    @Test("a file is referenced while any document row points at it, removed or not")
    func fileReferences() async throws {
        let store = try await StoreFixture.store()
        #expect(try await store.isFileReferenced(hash: "h1") == false)

        let entryID = try await Self.entry(store)
        let documentID = try await store.attach(Self.receipt(hash: "h1"), toEntry: entryID)
        #expect(try await store.isFileReferenced(hash: "h1"))

        try await store.softDeleteDocument(id: documentID)
        #expect(try await store.isFileReferenced(hash: "h1"))
        #expect(try await store.isFileReferenced(hash: "") == false)
    }
}
