import Testing
import Foundation
@testable import TaxData

@Suite("Document file store") struct DocumentFileStoreTests {

    static func store() throws -> DocumentFileStore {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "relio-files-\(UUID().uuidString)")
        return try DocumentFileStore(directory: directory)
    }

    @Test("bytes round-trip through the hash they are stored under")
    func roundTrips() throws {
        let store = try Self.store()
        let data = Data("a receipt".utf8)
        let stored = try store.write(data, extension: "jpg")

        #expect(stored.byteCount == data.count)
        #expect(stored.contentHash.count == 64)
        #expect(try store.read(hash: stored.contentHash, extension: "jpg") == data)
    }

    /// Content addressing is what makes `TaxStore.attach` able to refuse a second document
    /// for one photo — the same bytes have to land on the same name.
    @Test("the same bytes written twice are one file")
    func sameBytesAreOneFile() throws {
        let store = try Self.store()
        let data = Data("a receipt".utf8)
        let first = try store.write(data, extension: "jpg")
        let second = try store.write(data, extension: "jpg")

        #expect(first.contentHash == second.contentHash)
        #expect(first.url == second.url)
    }

    @Test("different bytes are different files")
    func differentBytesDiffer() throws {
        let store = try Self.store()
        let one = try store.write(Data("one".utf8), extension: "jpg")
        let two = try store.write(Data("two".utf8), extension: "jpg")
        #expect(one.contentHash != two.contentHash)
    }

    /// Spec §6 names this: the record exists and the bytes are gone, deleted from under
    /// the app. It has to be a nameable state rather than a generic file error, so the UI
    /// can offer to repair it instead of crashing.
    @Test("bytes deleted from under the app are reported as not stored")
    func missingBytesAreNamed() throws {
        let store = try Self.store()
        let stored = try store.write(Data("gone".utf8), extension: "jpg")
        try store.delete(hash: stored.contentHash, extension: "jpg")

        var reported = false
        do {
            _ = try store.read(hash: stored.contentHash, extension: "jpg")
        } catch DocumentFileStore.Failure.notStored {
            reported = true
        }
        #expect(reported)
    }

    @Test("deleting a file that is already gone is a no-op")
    func deleteIsIdempotent() throws {
        let store = try Self.store()
        #expect(throws: Never.self) {
            try store.delete(hash: String(repeating: "0", count: 64), extension: "jpg")
        }
    }
}
