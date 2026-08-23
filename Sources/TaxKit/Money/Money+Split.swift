import Foundation

extension Money {

    /// Divides into `n` parts that sum exactly to `self`.
    ///
    /// Any leftover sen go to the earliest parts, so the result is deterministic
    /// rather than dependent on iteration order.
    public func split(into n: Int) -> [Money] {
        precondition(n > 0, "Cannot split money into \(n) parts")
        return split(weights: Array(repeating: 1, count: n))
    }

    /// Divides in proportion to `weights`, using largest-remainder allocation so the
    /// parts sum exactly to `self`.
    public func split(weights: [Int]) -> [Money] {
        precondition(!weights.isEmpty, "Cannot split money across no weights")
        precondition(weights.allSatisfy { $0 >= 0 }, "Split weights must be non-negative")

        let totalWeight = weights.reduce(0, +)
        precondition(totalWeight > 0, "Split weights must not all be zero")

        // Work in the magnitude domain so truncation behaves like floor for both signs,
        // then reapply the sign once at the end.
        let sign = sen < 0 ? -1 : 1
        let magnitude = abs(sen)

        var floors: [Int] = []
        var remainders: [(index: Int, remainder: Int)] = []
        floors.reserveCapacity(weights.count)

        for (index, weight) in weights.enumerated() {
            let numerator = magnitude * weight
            floors.append(numerator / totalWeight)
            remainders.append((index, numerator % totalWeight))
        }

        var leftover = magnitude - floors.reduce(0, +)

        // Largest remainder first; ties break by original index for determinism.
        for entry in remainders.sorted(by: { ($0.remainder, -$0.index) > ($1.remainder, -$1.index) }) {
            guard leftover > 0 else { break }
            floors[entry.index] += 1
            leftover -= 1
        }

        return floors.map { Money(sen: $0 * sign) }
    }
}
