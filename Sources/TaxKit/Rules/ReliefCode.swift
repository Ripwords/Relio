import Foundation

/// A stable identifier for a relief category.
///
/// Entries reference reliefs by code rather than by relationship, so a code outlives any
/// single Year of Assessment's rules. Codes are **append-only and never reused**: when a
/// category merges into another, the ruleset declares an alias rather than deleting the
/// code, so historical entries continue to resolve.
///
/// The named constants live in `ReliefCode+Generated.swift`, produced by
/// `swift package generate-relief-codes` and guarded by `testGeneratedFileIsUpToDate`.
public struct ReliefCode: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
