import Foundation
import CryptoKit

/// Where a document's bytes actually live.
///
/// Content-addressed: the file is named for the SHA-256 of its contents, so importing the
/// same photo twice writes one file and `TaxStore.attach` recognises it by the same hash.
/// Dedupe falls out of the layout rather than needing a scan.
///
/// **Local only, deliberately, and not what spec §6 ultimately asks for.** That spec puts
/// the bytes in the app's iCloud Drive container so a seven-year archive can live outside
/// CloudKit while still following the user across devices, with `DocumentFile`'s
/// `DownloadState` tracking what is materialised here. This writes to Application Support
/// on one device. It matches what the app currently is — `StorageMode.local`, and a
/// Settings screen that says "This device only" — and it is the half that can be finished
/// and verified now. The iCloud half is a separate piece of work with its own failure
/// modes (spec §6 names three).
public struct DocumentFileStore: Sendable {

    /// What a write produced, which is exactly what `DocumentDraft` needs to record it.
    public struct Stored: Hashable, Sendable {
        public var contentHash: String
        public var byteCount: Int
        public var url: URL
    }

    public enum Failure: Error, Hashable, Sendable {
        case notStored
    }

    private let directory: URL

    /// - Parameter directory: overridable so tests write to a temporary directory rather
    ///   than the real container.
    public init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            self.directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: true)
                .appending(path: "Documents", directoryHint: .isDirectory)
        }
        try FileManager.default.createDirectory(at: self.directory,
                                                withIntermediateDirectories: true)
    }

    /// Writes the bytes and reports what they hash to.
    ///
    /// Idempotent: writing the same bytes twice is one file. That is the property
    /// `TaxStore.attach` leans on to refuse a second document for one photo.
    @discardableResult
    public func write(_ data: Data, extension fileExtension: String) throws -> Stored {
        let hash = Self.hash(data)
        let url = self.url(forHash: hash, extension: fileExtension)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try data.write(to: url, options: .atomic)
        }
        return Stored(contentHash: hash, byteCount: data.count, url: url)
    }

    public func read(hash: String, extension fileExtension: String) throws -> Data {
        let url = self.url(forHash: hash, extension: fileExtension)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            // The record exists and the bytes do not — deleted from under the app. Named
            // rather than thrown as a generic file error, because spec §6 wants this
            // surfaced as a repairable row rather than a crash.
            throw Failure.notStored
        }
        return try Data(contentsOf: url)
    }

    public func delete(hash: String, extension fileExtension: String) throws {
        let url = self.url(forHash: hash, extension: fileExtension)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func url(forHash hash: String, extension fileExtension: String) -> URL {
        directory.appending(path: fileExtension.isEmpty ? hash : "\(hash).\(fileExtension)")
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
