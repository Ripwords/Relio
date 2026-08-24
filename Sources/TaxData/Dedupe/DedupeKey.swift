import Foundation
import CryptoKit
import TaxKit

/// The keys that make duplicates detectable, since CloudKit will not let them be
/// prevented. Spec §6.
public enum DedupeKey {

    /// SHA-256 over the identifying tuple, lowercase hex.
    ///
    /// `|` is a safe separator because every component is already restricted to
    /// characters that cannot contain it: the code is `[A-Z_]`, the amount is digits,
    /// the day is `yyyy-MM-dd`, and `Normalisation.vendor` emits only alphanumerics and
    /// single spaces. Without that guarantee, ("AB", 1) and ("A", "B1") would collide.
    public static func entry(code: ReliefCode,
                             amountSen: Int,
                             day: String,
                             vendor: String) -> String {
        hex(of: "\(code.rawValue)|\(amountSen)|\(day)|\(vendor)")
    }

    /// SHA-256 of a file's bytes — catches the same photo imported on two devices with
    /// different metadata.
    public static func content(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(of string: String) -> String {
        content(Data(string.utf8))
    }
}
