import Foundation
import CryptoKit
import TaxKit

/// The keys that make duplicates detectable, since CloudKit will not let them be
/// prevented. Spec §6.
public enum DedupeKey {

    /// SHA-256 over a length-prefixed encoding of the identifying tuple, lowercase hex.
    ///
    /// Length-prefixing, not a delimiter convention: `ReliefCode` performs no character
    /// validation, and `ReliefEntry.reliefCodeRaw` is a plain stored `String` that
    /// CloudKit sync writes into directly, so a record from a future build — or a
    /// corrupted one — can carry any byte a delimiter might rely on being absent. A
    /// naive `"\(code)|\(amountSen)|\(day)|\(vendor)"` join lets
    /// `("A|1", 23, "D", "V")` and `("A", 1, "23", "D|V")` flatten to the identical
    /// string; `componentsCannotBeSmuggledAcrossTheEncoding` in `DedupeTests` pins
    /// exactly that collision.
    ///
    /// `year`, `claimant` and `dependentID` are part of the tuple, not incidental to it:
    /// a receipt belongs to exactly one Year of Assessment, one claimant and at most one
    /// dependent. Without them an undated recurring claim — SSPN, LIFE_INSURANCE, a
    /// LIFESTYLE entry typed with no receipt date, since `Normalisation.day(nil)` is
    /// `""` and `EntryDraft.spentOn` defaults to `nil` — logged in two different years
    /// hashes identically, and the sweep would silently soft-delete a whole year's claim.
    /// The same gap let two children's identical claims in one year collapse into one.
    /// `dependentID` renders as its `uuidString`, or `""` when the claimant has none.
    public static func entry(year: Int,
                             code: ReliefCode,
                             amountSen: Int,
                             day: String,
                             vendor: String,
                             claimant: Claimant,
                             dependentID: UUID?) -> String {
        hex(of: encode([String(year), code.rawValue, String(amountSen), day, vendor,
                        claimant.rawValue, dependentID?.uuidString ?? ""]))
    }

    /// SHA-256 of a file's bytes — catches the same photo imported on two devices with
    /// different metadata.
    public static func content(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Encodes each component as `"<utf8ByteCount>:<component>"`, joined by `|` between
    /// components purely for human readability.
    ///
    /// This is injective for arbitrary component content, with no assumption about
    /// which characters a component may hold: a reader always knows, from the prefix
    /// alone, exactly how many bytes to consume as the component's own content, so
    /// nothing inside a component — a `|`, a digit, a colon, anything — can be misread
    /// as a boundary. The `|` separators between entries carry no parsing weight and
    /// could be removed without changing what the encoding distinguishes; they stay
    /// only to make the hashed string legible while debugging.
    private static func encode(_ components: [String]) -> String {
        components
            .map { "\(Data($0.utf8).count):\($0)" }
            .joined(separator: "|")
    }

    private static func hex(of string: String) -> String {
        content(Data(string.utf8))
    }
}
