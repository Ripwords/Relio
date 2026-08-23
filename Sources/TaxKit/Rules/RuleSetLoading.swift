import Foundation

public enum RuleSetLoadingError: Error, Hashable, Sendable {
    case noRulesForYear(Int)
    case malformed(year: Int, underlying: String)
}

/// Where rulebooks come from.
///
/// A protocol rather than a concrete type so a remote or CloudKit-backed source can be
/// substituted without touching any feature code. Nothing downstream names a concrete
/// loader.
public protocol RuleSetLoading: Sendable {
    var availableYears: [Int] { get }
    func ruleSet(for year: Int) throws -> RuleSet
}

/// Reads the rulebooks shipped inside TaxKit.
public struct BundledRuleSetLoader: RuleSetLoading {
    public let availableYears: [Int]

    public init(availableYears: [Int] = [2023, 2024, 2025]) {
        self.availableYears = availableYears.sorted()
    }

    public func ruleSet(for year: Int) throws -> RuleSet {
        guard availableYears.contains(year),
              let url = RuleBundle.current.url(forResource: "ya-\(year)",
                                               withExtension: "json",
                                               subdirectory: "Rules")
        else { throw RuleSetLoadingError.noRulesForYear(year) }

        do {
            return try JSONDecoder().decode(RuleSet.self, from: try Data(contentsOf: url))
        } catch {
            throw RuleSetLoadingError.malformed(year: year, underlying: "\(error)")
        }
    }
}
