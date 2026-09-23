import Foundation
import SwiftData
import TaxKit

/// One attached receipt, invoice or certificate, as a value.
///
/// The bytes are not here. `contentHash` and `byteCount` describe a file the caller has
/// already written somewhere; `thumbnail` is the ~30 KB preview that is small enough to
/// sync. Spec §6 keeps full-resolution bytes out of CloudKit, and keeping them out of this
/// type is what stops them arriving there by accident.
public struct DocumentDraft: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: DocumentKind
    public var vendor: String
    public var documentDate: Date?
    public var total: Money?
    /// The only image bytes that sync. Nil until the caller has one.
    public var thumbnail: Data?
    public var byteCount: Int
    /// SHA-256 of the file. What makes attaching the same photo twice one document.
    public var contentHash: String
    /// Uniform Type Identifier, e.g. `public.jpeg`, `com.adobe.pdf`.
    public var uti: String
    /// Every line the recogniser read, joined. What a later search or the assistant reads;
    /// nothing is derived from it here.
    public var ocrText: String?
    /// The MyInvois document UUID from the receipt's QR. A dedupe key and a badge — it
    /// never changes `kind`, because which document a relief accepts is the rulebook's
    /// call, not the QR's.
    public var eInvoiceUUID: String?

    public init(id: UUID = UUID(),
                kind: DocumentKind = .officialReceipt,
                vendor: String = "",
                documentDate: Date? = nil,
                total: Money? = nil,
                thumbnail: Data? = nil,
                byteCount: Int = 0,
                contentHash: String = "",
                uti: String = "public.jpeg",
                ocrText: String? = nil,
                eInvoiceUUID: String? = nil) {
        self.id = id
        self.kind = kind
        self.vendor = vendor
        self.documentDate = documentDate
        self.total = total
        self.thumbnail = thumbnail
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.uti = uti
        self.ocrText = ocrText
        self.eInvoiceUUID = eInvoiceUUID
    }

    /// Whether this row has a MyInvois e-invoice UUID — what the "MyInvois e-invoice"
    /// badge is shown for. The UUID itself is never displayed.
    public var isEInvoice: Bool { eInvoiceUUID != nil }
}

extension TaxStore {

    /// Attaches a document to an entry and re-derives whether the claim is still short of
    /// one.
    ///
    /// Every other piece of this loop has existed since the first plan — `Document`,
    /// `DocumentFile`, `ReliefEntry.documentKinds`, and `refreshDerivedFields` recomputing
    /// `needsDocument` from them. Only this was missing, so the app could tell a user a
    /// claim was missing a receipt and nothing could ever stop it saying so.
    ///
    /// - Returns: the document's identity. Attaching a file already on this entry returns
    ///   the existing one rather than creating a second: `contentHash` is there to catch
    ///   the same photo imported twice, which the model's own doc comment says and nothing
    ///   until now enforced.
    @discardableResult
    public func attach(_ draft: DocumentDraft, toEntry entryID: UUID) throws -> UUID {
        guard let entry = try modelContext.fetch(FetchDescriptor<ReliefEntry>(
            predicate: #Predicate { $0.id == entryID && $0.deletedAt == nil })).first
        else {
            // An entry that is gone — deleted on another device, most likely. Attaching
            // to nothing is a no-op rather than an orphaned document nobody can reach.
            throw DocumentAttachmentError.noSuchEntry
        }

        // The same photo twice, or the same e-invoice twice as two different files — a
        // PDF downloaded from the portal and a photo of the printout share a UUID and
        // nothing else.
        let hash = draft.contentHash
        let uuid = draft.eInvoiceUUID
        if let existing = (entry.documents ?? []).first(where: { document in
            document.isLive
                && ((!hash.isEmpty && document.file?.contentHash == hash)
                    || (uuid != nil && document.eInvoiceUUID == uuid))
        }) {
            return existing.id
        }

        let stamp = now()
        let document = Document(id: draft.id)
        document.kind = draft.kind
        document.vendor = draft.vendor
        document.documentDate = draft.documentDate
        document.total = draft.total
        document.thumbnail = draft.thumbnail
        document.ocrText = draft.ocrText
        document.eInvoiceUUID = draft.eInvoiceUUID
        document.updatedAt = stamp

        let file = DocumentFile(id: UUID())
        file.uti = draft.uti
        file.byteCount = draft.byteCount
        file.contentHash = hash
        file.updatedAt = stamp
        file.document = document

        modelContext.insert(document)
        modelContext.insert(file)
        entry.documents = (entry.documents ?? []) + [document]
        entry.updatedAt = stamp
        // The whole point: the flag every screen reads is re-derived from what the entry
        // now carries, rather than staying stale until the next edit.
        refreshDerivedFields(on: entry)
        try modelContext.save()
        return document.id
    }

    public func documentDrafts(forEntry entryID: UUID) throws -> [DocumentDraft] {
        guard let entry = try modelContext.fetch(FetchDescriptor<ReliefEntry>(
            predicate: #Predicate { $0.id == entryID && $0.deletedAt == nil })).first
        else { return [] }
        return (entry.documents ?? [])
            .filter(\.isLive)
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { document in
                DocumentDraft(id: document.id,
                              kind: document.kind,
                              vendor: document.vendor,
                              documentDate: document.documentDate,
                              total: document.total,
                              thumbnail: document.thumbnail,
                              byteCount: document.file?.byteCount ?? 0,
                              contentHash: document.file?.contentHash ?? "",
                              uti: document.file?.uti ?? "public.data",
                              ocrText: document.ocrText,
                              eInvoiceUUID: document.eInvoiceUUID)
            }
    }

    /// Soft delete, and re-derive every entry the document was supporting.
    ///
    /// Removing a receipt puts its claim back to unsupported, which is a consequence the
    /// user should see immediately rather than at the next edit.
    public func softDeleteDocument(id: UUID) throws {
        guard let document = try documentRow(id), document.deletedAt == nil else { return }
        let stamp = now()
        document.deletedAt = stamp
        document.updatedAt = stamp
        for entry in document.entries ?? [] { refreshDerivedFields(on: entry) }
        try modelContext.save()
    }

    /// Undoes `softDeleteDocument`, on the same terms as every other restore here.
    public func restoreDocument(id: UUID) throws {
        guard let document = try documentRow(id), document.deletedAt != nil else { return }
        document.deletedAt = nil
        document.updatedAt = now()
        for entry in document.entries ?? [] { refreshDerivedFields(on: entry) }
        try modelContext.save()
    }

    private func documentRow(_ id: UUID) throws -> Document? {
        try modelContext.fetch(
            FetchDescriptor<Document>(predicate: #Predicate { $0.id == id })).first
    }

    /// The other claims this file or e-invoice already supports — what the duplicate
    /// warning prints. Spec §5: warned about, never blocked, because one bill can
    /// honestly split across two reliefs.
    ///
    /// Only a live document on a live, unmerged entry counts. A receipt the user took off
    /// a claim supports nothing, and warning about it would be warning about nothing.
    public func claimsSupported(byHash hash: String,
                                orEInvoiceUUID uuid: String?,
                                excludingEntry excluded: UUID?) throws -> [SupportedClaim] {
        var documents: [Document] = []
        if !hash.isEmpty {
            documents += try modelContext.fetch(FetchDescriptor<DocumentFile>(
                predicate: #Predicate { $0.contentHash == hash }))
                .compactMap(\.document)
        }
        if uuid != nil {
            // Optional to optional, so the predicate macro compares like with like.
            let match: String? = uuid
            documents += try modelContext.fetch(FetchDescriptor<Document>(
                predicate: #Predicate { $0.eInvoiceUUID == match }))
        }

        let liveDocuments: [Document] = documents.filter(\.isLive)
        let candidateEntries: [ReliefEntry] = liveDocuments.flatMap { $0.entries ?? [] }
        let eligibleEntries: [ReliefEntry] = candidateEntries.filter {
            $0.isLive && $0.mergedInto == nil && $0.id != excluded
        }

        var seen: Set<UUID> = []
        let deduped: [ReliefEntry] = eligibleEntries.filter { seen.insert($0.id).inserted }
        let claims: [SupportedClaim] = deduped.map {
            SupportedClaim(entryID: $0.id, code: $0.reliefCode,
                           amount: $0.amount, spentOn: $0.spentOn)
        }
        return claims.sorted(by: Self.isEarlier)
    }

    /// Earliest `spentOn` first, undated last, ties broken on entry id for a stable order.
    private static func isEarlier(_ lhs: SupportedClaim, _ rhs: SupportedClaim) -> Bool {
        switch (lhs.spentOn, rhs.spentOn) {
        case let (l?, r?):
            if l != r { return l < r }
            return lhs.entryID.uuidString < rhs.entryID.uuidString
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.entryID.uuidString < rhs.entryID.uuidString
        }
    }

    /// Whether any document row points at this file. Cancelling a scan deletes the file it
    /// wrote only when this is false.
    ///
    /// Soft-deleted rows count: `restoreDocument` would bring the row back, and a restored
    /// receipt whose file had been deleted underneath it is a thumbnail with nothing behind
    /// it. Deliberately stricter than "a live `DocumentFile`" (spec §5) for that reason.
    public func isFileReferenced(hash: String) throws -> Bool {
        guard !hash.isEmpty else { return false }
        var descriptor = FetchDescriptor<DocumentFile>(
            predicate: #Predicate { $0.contentHash == hash })
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }
}

public enum DocumentAttachmentError: Error, Hashable, Sendable {
    /// The entry is gone. Attaching to it would create a document nothing can reach.
    case noSuchEntry
}

/// Another claim a receipt already supports: what the duplicate warning prints, and
/// nothing more.
public struct SupportedClaim: Hashable, Sendable {
    public var entryID: UUID
    public var code: ReliefCode
    public var amount: Money
    public var spentOn: Date?

    public init(entryID: UUID, code: ReliefCode, amount: Money, spentOn: Date?) {
        self.entryID = entryID
        self.code = code
        self.amount = amount
        self.spentOn = spentOn
    }
}
