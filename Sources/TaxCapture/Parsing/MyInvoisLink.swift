import Foundation

/// A MyInvois validation link read from an e-invoice's QR code.
///
/// Strict on purpose. A QR is attacker-controllable input — anyone can print one — and
/// the only thing this does with it is record an ID, so accepting a near-miss buys
/// nothing and risks recording a stranger's string as an e-invoice. Nothing here opens
/// the link: spec §2, no network.
public struct MyInvoisLink: Hashable, Sendable {
    public let uuid: String
    public let longId: String

    static let hosts: Set<String> = ["myinvois.hasil.gov.my", "preprod.myinvois.hasil.gov.my"]

    public init?(_ payload: String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), Self.hosts.contains(host),
              parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil
        else { return nil }

        let path = parts.percentEncodedPath
        guard path.hasPrefix("/"), !path.hasSuffix("/") else { return nil }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[1] == "share",
              segments[0].wholeMatch(of: /[A-Za-z0-9]{10,40}/) != nil,
              segments[2].wholeMatch(of: /[A-Za-z0-9]{10,200}/) != nil
        else { return nil }

        uuid = String(segments[0])
        longId = String(segments[2])
    }
}
