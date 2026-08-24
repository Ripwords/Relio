import Foundation
import SwiftData

/// Where a document's bytes are and whether they are on this device.
///
/// Progress is an `Int` percentage, not the `Double` spec §6 sketches: the package bans
/// `Double` outside charting, and a progress bar does not need sub-percent resolution.
public enum DownloadState: Hashable, Sendable {
    case local
    case notDownloaded
    case downloading(percent: Int)
    case uploading
    /// The record exists but the file is gone — deleted in Files.app, most likely.
    /// Surfaces as a repairable amber row rather than a crash. Spec §6.
    case missing
}

@Model
public final class DocumentFile {

    public var id: UUID = UUID()
    /// Uniform Type Identifier, e.g. `public.jpeg`, `com.adobe.pdf`.
    public var uti: String = "public.jpeg"
    public var byteCount: Int = 0
    /// SHA-256 of the normalised bytes. Catches the same photo imported twice.
    public var contentHash: String = ""
    public var downloadStateRaw: String = "local"
    public var downloadProgressPercent: Int = 100

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    @Relationship(inverse: \Document.file)
    public var document: Document?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

extension DocumentFile {

    public var downloadState: DownloadState {
        get {
            switch downloadStateRaw {
            case "local": return .local
            case "notDownloaded": return .notDownloaded
            case "downloading": return .downloading(percent: downloadProgressPercent)
            case "uploading": return .uploading
            case "missing": return .missing
            default: return .notDownloaded
            }
        }
        set {
            switch newValue {
            case .local:
                downloadStateRaw = "local"
                downloadProgressPercent = 100
            case .notDownloaded:
                downloadStateRaw = "notDownloaded"
                downloadProgressPercent = 0
            case .downloading(let percent):
                downloadStateRaw = "downloading"
                downloadProgressPercent = Swift.min(100, Swift.max(0, percent))
            case .uploading:
                downloadStateRaw = "uploading"
            case .missing:
                downloadStateRaw = "missing"
                downloadProgressPercent = 0
            }
        }
    }

    public var isLive: Bool { deletedAt == nil }
}
