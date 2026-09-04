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

    public init(id: UUID = UUID(),
                kind: DocumentKind = .officialReceipt,
                vendor: String = "",
                documentDate: Date? = nil,
                total: Money? = nil,
                thumbnail: Data? = nil,
                byteCount: Int = 0,
                contentHash: String = "",
                uti: String = "public.jpeg") {
        self.id = id
        self.kind = kind
        self.vendor = vendor
        self.documentDate = documentDate
        self.total = total
        self.thumbnail = thumbnail
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.uti = uti
    }
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

        let hash = draft.contentHash
        if !hash.isEmpty,
           let existing = (entry.documents ?? [])
               .first(where: { $0.isLive && $0.file?.contentHash == hash }) {
            return existing.id
        }

        let stamp = now()
        let document = Document(id: draft.id)
        document.kind = draft.kind
        document.vendor = draft.vendor
        document.documentDate = draft.documentDate
        document.total = draft.total
        document.thumbnail = draft.thumbnail
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
                              uti: document.file?.uti ?? "public.data")
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
}

public enum DocumentAttachmentError: Error, Hashable, Sendable {
    /// The entry is gone. Attaching to it would create a document nothing can reach.
    case noSuchEntry
}
