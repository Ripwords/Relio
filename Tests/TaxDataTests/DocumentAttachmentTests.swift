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
