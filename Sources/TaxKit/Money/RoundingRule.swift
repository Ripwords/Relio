import Foundation

/// How a fractional sen is resolved to a whole sen.
///
/// Malaysian tax rounds half-up, so `.halfUp` is the default everywhere in TaxKit.
/// The other cases exist because the call site should always be explicit when it
/// deviates, rather than relying on a hidden global.
public enum RoundingRule: String, Codable, Sendable, CaseIterable {
    /// Ties away from zero: 0.5 to 1, -0.5 to -1.
    case halfUp
    /// Toward zero.
    case down
    /// Away from zero.
    case up
    /// Ties to even: 0.5 to 0, 1.5 to 2.
    case bankers

    var nsMode: NSDecimalNumber.RoundingMode {
        switch self {
        case .halfUp:  .plain
        case .down:    .down
        case .up:      .up
        case .bankers: .bankers
        }
    }
}
