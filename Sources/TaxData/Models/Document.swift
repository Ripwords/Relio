import Foundation
import SwiftData
import TaxKit

/// A receipt, invoice or certificate: its metadata and a small thumbnail.
///
/// The full-resolution bytes do not live here and do not live in CloudKit. They go to the
/// app's iCloud Drive container, identified by `DocumentFile`. Only the ~30 KB thumbnail
/// is mirrored, which is what keeps a seven-year archive syncing to a Watch. Spec §6.
@Model
public final class Document {

    public var id: UUID = UUID()
    public var kindRaw: String = DocumentKind.officialReceipt.rawValue
    public var vendor: String = ""
    public var documentDate: Date?
    public var totalSen: Int?

    /// Populated by the document pipeline in a later plan. Nil here is normal.
    public var ocrText: String?
    /// From a MyInvois QR payload. The strongest dedupe key when present.
    public var eInvoiceUUID: String?
    /// ~30 KB. The only image bytes that sync.
    public var thumbnail: Data?

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    public var entries: [ReliefEntry]?
    public var file: DocumentFile?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

extension Document {

    public var kind: DocumentKind {
        get { DocumentKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    public var total: Money? {
        get { totalSen.map(Money.init(sen:)) }
        set { totalSen = newValue?.sen }
    }

    public var isLive: Bool { deletedAt == nil }
}
