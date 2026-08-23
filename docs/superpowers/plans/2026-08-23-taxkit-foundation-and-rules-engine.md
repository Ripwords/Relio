# TaxKit Foundation & Rules Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a tested Swift package that, given a taxpayer's profile and their logged entries, returns per-relief assessments — cap, claimed, headroom, eligibility, documentary requirements and estimated tax saved — for Malaysian Years of Assessment 2023 to 2025, plus year-over-year rule diffs.

**Architecture:** A pure Swift package with no SwiftData, SwiftUI or platform dependency, so all Malaysian tax logic is testable with `swift test` and never needs a simulator. Money is a value type over whole sen with no `Double` in any calculation path. The rulebook is versioned JSON decoded into a closed, non-executable predicate language; evaluation is one pure function.

**Tech Stack:** Swift 6.3, Swift Package Manager (tools 6.2), swift-testing (`import Testing`), Foundation `Decimal` for rate arithmetic, `CryptoKit` not required in this plan.

**Spec:** `docs/superpowers/specs/2026-08-23-malaysian-tax-relief-tracker-design.md`

## Global Constraints

- Swift tools version `6.2`; platforms `.iOS(.v26)`, `.macOS(.v26)`, `.watchOS(.v26)`.
- Strict concurrency: every public type in this plan is `Sendable`. No `@unchecked Sendable`.
- **No `Double` in any calculation path.** The only `Double` in `TaxKit` is `Money.lossyDoubleForCharting`.
- Rates are `Decimal` fractions, not percentages: 19% is `0.19`.
- Malaysian tax rounds **half-up**. `RoundingRule.halfUp` is the default everywhere.
- Money is always whole sen. `RM 2,500.00` is `Money(sen: 250_000)`.
- One formatter only: `Money.formatted()` produces `RM 2,500.00`. Interpolating an amount into user-facing text anywhere else is a defect; the Definition of Done carries the check.
- Relief codes are append-only and never reused. Retiring a code requires an alias entry.
- Every relief in every ruleset carries a non-empty `sourceURL` and a `verifiedOn` date.
- Any figure not verifiable against hasil.gov.my is marked `"unverified": true` and excluded from tax-saved maths.
- TDD: the failing test is written and observed failing before the implementation, in every task.
- Conventional Commits (`feat:`, `fix:`, `test:`, `chore:`, `docs:`).

## File Structure

```
Package.swift                              package manifest, 3 targets + 1 plugin
Sources/TaxKit/
  Money/
    Money.swift                            value type, arithmetic, overflow traps
    RoundingRule.swift                     half-up / down / up / bankers
    Money+Split.swift                      largest-remainder allocation
    Money+Formatting.swift                 the single en_MY formatter
  Rules/
    ReliefCode.swift                       RawRepresentable wrapper (hand-written core)
    ReliefCode+Generated.swift             GENERATED — one constant per code
    Cap.swift                              fixed / sharedPool / perDependent / tiered / none
    DocumentKind.swift                     receipt, medical certificate, e-invoice, ...
    EligibilityPredicate.swift             closed Codable predicate tree + Facts
    ReliefRule.swift                       one relief, possibly with children
    RuleSet.swift                          one Year of Assessment
    RuleSetLoading.swift                   protocol + BundledRuleSetLoader
    RuleSetDiff.swift                      ReliefDelta and diff(_:_:)
  Engine/
    BracketTable.swift                     bands with precomputed cumulative base
    TaxCalculator.swift                    tax(on:), marginalRate(at:), taxSaved
    Snapshots.swift                        TaxYearSnapshot, EntrySnapshot, DependentSnapshot
    ReliefAssessment.swift                 the evaluator's output type
    Evaluator.swift                        evaluate(ruleSet:year:entries:)
    Counterfactual.swift                   replay entries under another ruleset
  Resources/Rules/
    ya-2023.json  ya-2024.json  ya-2025.json
Sources/ReliefCodeGenerator/main.swift     reads the JSON, emits ReliefCode+Generated.swift
Plugins/GenerateReliefCodes/plugin.swift   `swift package generate-relief-codes`
Tests/TaxKitTests/
  MoneyTests.swift            MoneySplitTests.swift        MoneyFormattingTests.swift
  ReliefCodeTests.swift       RuleSetDecodingTests.swift   EligibilityTests.swift
  RulebookIntegrityTests.swift                             BracketTableTests.swift
  EvaluatorCapTests.swift     EvaluatorPoolTests.swift     EvaluatorDependentTests.swift
  EvaluatorEligibilityTests.swift                          TaxSavedTests.swift
  RuleSetDiffTests.swift      GoldenFileTests.swift
  Fixtures/                   golden JSON per YA
```

### Deviation from the spec, and why

Spec §7 calls for an **SPM build tool plugin** to generate `ReliefCode`. This plan uses a
**command plugin** with a checked-in generated file plus a staleness test instead.

Build tool plugins emit into a derived directory, so the generated constants are invisible
to the editor until after a build, and Xcode prompts for plugin trust on every clean
checkout. A checked-in generated file is reviewable in diffs, works in the editor
immediately, and `testGeneratedFileIsUpToDate` fails the suite the moment the JSON and the
Swift drift apart — the same guarantee, enforced at test time rather than build time.

---

### Task 1: Package scaffold and the `Money` value type

**Files:**
- Create: `Package.swift`
- Create: `Sources/TaxKit/Money/Money.swift`
- Test: `Tests/TaxKitTests/MoneyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Money` — `init(sen: Int)`, `init(ringgit: Decimal)`, `var sen: Int`,
  `static let zero`, `+`, `-`, `<`, `==`, `func clamped(to: Money) -> Money`,
  `var lossyDoubleForCharting: Double`. Conforms to `Hashable, Codable, Sendable, Comparable`.

- [ ] **Step 1: Create the package manifest**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TaxKit",
    platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "TaxKit", targets: ["TaxKit"])
    ],
    targets: [
        .target(
            name: "TaxKit",
            resources: [.copy("Resources/Rules")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TaxKitTests",
            dependencies: ["TaxKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
```

Create the resource directories so the manifest resolves:

```bash
mkdir -p Sources/TaxKit/{Money,Rules,Engine,Resources/Rules} Tests/TaxKitTests/Fixtures
echo '{}' > Sources/TaxKit/Resources/Rules/.keep.json
echo '{}' > Tests/TaxKitTests/Fixtures/.keep.json
```

- [ ] **Step 2: Write the failing test**

Create `Tests/TaxKitTests/MoneyTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("Money") struct MoneyTests {

    @Test("sen is the canonical representation")
    func senIsCanonical() {
        #expect(Money(sen: 250_000).sen == 250_000)
        #expect(Money.zero.sen == 0)
    }

    @Test("ringgit initialiser rounds half-up to whole sen")
    func ringgitRoundsHalfUp() {
        #expect(Money(ringgit: Decimal(string: "2500.00")!).sen == 250_000)
        #expect(Money(ringgit: Decimal(string: "0.005")!).sen == 1)
        #expect(Money(ringgit: Decimal(string: "0.004")!).sen == 0)
        #expect(Money(ringgit: Decimal(string: "-0.005")!).sen == -1)
    }

    @Test("addition and subtraction are exact")
    func arithmeticIsExact() {
        let a = Money(ringgit: Decimal(string: "0.10")!)
        let b = Money(ringgit: Decimal(string: "0.20")!)
        #expect((a + b).sen == 30)          // the classic 0.1 + 0.2 Double failure
        #expect((a + b - b) == a)
    }

    @Test("comparison orders by sen")
    func comparisonOrders() {
        #expect(Money(sen: 100) < Money(sen: 101))
        #expect(Money(sen: -1) < Money.zero)
    }

    @Test("clamped never exceeds the cap and never invents value")
    func clampedBounds() {
        let cap = Money(sen: 250_000)
        #expect(Money(sen: 300_000).clamped(to: cap) == cap)
        #expect(Money(sen: 100_000).clamped(to: cap).sen == 100_000)
        #expect(Money(sen: -5).clamped(to: cap).sen == -5)
    }

    @Test("Codable round-trips")
    func codableRoundTrip() throws {
        let original = Money(sen: 123_456)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Money.self, from: data) == original)
    }
}
```

- [ ] **Step 3: Run the test and confirm it fails**

Run: `swift test --filter MoneyTests`
Expected: FAIL — `cannot find 'Money' in scope`.

- [ ] **Step 4: Implement `Money`**

Create `Sources/TaxKit/Money/Money.swift`:

```swift
import Foundation

/// An exact amount of Malaysian ringgit, stored as a whole number of sen.
///
/// There is deliberately no `Double` arithmetic. Multiplying money by a rate goes
/// through `applying(_:rounding:)`; dividing money goes through `split`.
public struct Money: Hashable, Codable, Sendable, Comparable {

    /// The canonical value. RM 2,500.00 is 250_000 sen.
    public private(set) var sen: Int

    public static let zero = Money(sen: 0)

    public init(sen: Int) {
        self.sen = sen
    }

    /// Converts ringgit to sen, rounding half-up (ties away from zero).
    public init(ringgit: Decimal) {
        var scaled = ringgit * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let number = NSDecimalNumber(decimal: rounded)
        precondition(
            number.compare(NSDecimalNumber(value: Int.max)) != .orderedDescending
                && number.compare(NSDecimalNumber(value: Int.min)) != .orderedAscending,
            "Money out of representable range: \(ringgit)"
        )
        self.sen = number.intValue
    }

    public static func + (lhs: Money, rhs: Money) -> Money {
        let (result, overflow) = lhs.sen.addingReportingOverflow(rhs.sen)
        precondition(!overflow, "Money addition overflowed")
        return Money(sen: result)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        let (result, overflow) = lhs.sen.subtractingReportingOverflow(rhs.sen)
        precondition(!overflow, "Money subtraction overflowed")
        return Money(sen: result)
    }

    public static func < (lhs: Money, rhs: Money) -> Bool { lhs.sen < rhs.sen }

    /// Returns `self` if it is at or below `cap`, otherwise `cap`.
    /// Values below zero are returned unchanged — clamping is an upper bound only.
    public func clamped(to cap: Money) -> Money {
        sen > cap.sen ? cap : self
    }

    /// Charting only. Named to discourage use; never appears in a calculation path.
    public var lossyDoubleForCharting: Double { Double(sen) / 100 }
}
```

- [ ] **Step 5: Run the test and confirm it passes**

Run: `swift test --filter MoneyTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/TaxKit Tests/TaxKitTests
git commit -m "feat: add Money value type over whole sen"
```

---

### Task 2: Rate application and rounding rules

**Files:**
- Create: `Sources/TaxKit/Money/RoundingRule.swift`
- Modify: `Sources/TaxKit/Money/Money.swift` (append `applying`)
- Test: `Tests/TaxKitTests/MoneyTests.swift` (append a suite)

**Interfaces:**
- Consumes: `Money` from Task 1.
- Produces: `RoundingRule` (`.halfUp`, `.down`, `.up`, `.bankers`) and
  `Money.applying(_ rate: Decimal, rounding: RoundingRule = .halfUp) -> Money`.
  **`rate` is a fraction: 19% is `0.19`.**

- [ ] **Step 1: Write the failing test**

Append to `Tests/TaxKitTests/MoneyTests.swift`:

```swift
@Suite("Money.applying") struct MoneyRateTests {

    @Test("applies a fractional rate and rounds half-up by default")
    func appliesRate() {
        // RM 800.00 at 19% is RM 152.00 exactly.
        #expect(Money(sen: 80_000).applying(Decimal(string: "0.19")!).sen == 15_200)
    }

    @Test("half-up is the default at an exact .5 sen boundary")
    func halfUpAtBoundary() {
        // 1 sen at 50% is 0.5 sen, which rounds up to 1.
        #expect(Money(sen: 1).applying(Decimal(string: "0.5")!).sen == 1)
        // 3 sen at 50% is 1.5 sen, which rounds up to 2.
        #expect(Money(sen: 3).applying(Decimal(string: "0.5")!).sen == 2)
    }

    @Test("explicit rounding rules override the default")
    func explicitRounding() {
        let one = Money(sen: 1)
        let half = Decimal(string: "0.5")!
        #expect(one.applying(half, rounding: .down).sen == 0)
        #expect(one.applying(half, rounding: .up).sen == 1)
        #expect(one.applying(half, rounding: .bankers).sen == 0)   // ties to even
        #expect(Money(sen: 3).applying(half, rounding: .bankers).sen == 2)
    }

    @Test("negative amounts round away from zero under half-up")
    func negativeHalfUp() {
        #expect(Money(sen: -1).applying(Decimal(string: "0.5")!).sen == -1)
    }

    @Test("a zero rate yields zero and a rate of one is the identity")
    func degenerateRates() {
        let m = Money(sen: 123_456)
        #expect(m.applying(Decimal(0)) == .zero)
        #expect(m.applying(Decimal(1)) == m)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter MoneyRateTests`
Expected: FAIL — `value of type 'Money' has no member 'applying'`.

- [ ] **Step 3: Implement `RoundingRule`**

Create `Sources/TaxKit/Money/RoundingRule.swift`:

```swift
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
```

- [ ] **Step 4: Implement `applying`**

Append to `Sources/TaxKit/Money/Money.swift`, inside the `Money` struct:

```swift
    /// Multiplies by a rate expressed as a fraction — pass `0.19` for 19%.
    ///
    /// This is the only way to apply a percentage to money. There is no
    /// `Money * Money`, because multiplying two amounts is never meaningful here.
    public func applying(_ rate: Decimal, rounding: RoundingRule = .halfUp) -> Money {
        var product = Decimal(sen) * rate
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, rounding.nsMode)
        return Money(sen: NSDecimalNumber(decimal: rounded).intValue)
    }
```

- [ ] **Step 5: Run the test and confirm it passes**

Run: `swift test --filter MoneyRateTests`
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/TaxKit/Money Tests/TaxKitTests/MoneyTests.swift
git commit -m "feat: add explicit rounding rules and rate application to Money"
```

---

### Task 3: Largest-remainder splitting

**Files:**
- Create: `Sources/TaxKit/Money/Money+Split.swift`
- Test: `Tests/TaxKitTests/MoneySplitTests.swift`

**Interfaces:**
- Consumes: `Money` from Task 1.
- Produces: `Money.split(into n: Int) -> [Money]` and
  `Money.split(weights: [Int]) -> [Money]`. Both guarantee the parts sum exactly to the
  original. Used later for 50/50 spouse child relief and shared-pool allocation.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxKitTests/MoneySplitTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("Money.split") struct MoneySplitTests {

    @Test("an even split is exact")
    func evenSplit() {
        let parts = Money(ringgit: 2000).split(into: 2)
        #expect(parts.map(\.sen) == [100_000, 100_000])
    }

    @Test("an uneven split distributes the remainder to the earliest parts")
    func unevenSplit() {
        // RM 2,500.00 into three is 833.34 / 833.33 / 833.33
        let parts = Money(ringgit: 2500).split(into: 3)
        #expect(parts.map(\.sen) == [83_334, 83_333, 83_333])
    }

    @Test("parts always sum back to the original, for every divisor up to 50")
    func splitAlwaysSums() {
        for sen in [0, 1, 7, 99, 100, 250_000, 999_999, 1_000_003] {
            for n in 1...50 {
                let original = Money(sen: sen)
                let total = original.split(into: n).reduce(Money.zero, +)
                #expect(total == original, "sen=\(sen) n=\(n)")
            }
        }
    }

    @Test("weighted splits honour the weights and still sum exactly")
    func weightedSplit() {
        let parts = Money(sen: 1000).split(weights: [1, 3])
        #expect(parts.map(\.sen) == [250, 750])

        let awkward = Money(sen: 100).split(weights: [1, 1, 1])
        #expect(awkward.map(\.sen) == [34, 33, 33])
        #expect(awkward.reduce(Money.zero, +).sen == 100)
    }

    @Test("negative amounts split without losing a sen")
    func negativeSplit() {
        let parts = Money(sen: -100).split(into: 3)
        #expect(parts.reduce(Money.zero, +).sen == -100)
        #expect(parts.map(\.sen) == [-34, -33, -33])
    }

    @Test("a single part returns the whole")
    func singlePart() {
        #expect(Money(sen: 777).split(into: 1).map(\.sen) == [777])
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter MoneySplitTests`
Expected: FAIL — `value of type 'Money' has no member 'split'`.

- [ ] **Step 3: Implement the split**

Create `Sources/TaxKit/Money/Money+Split.swift`:

```swift
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
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `swift test --filter MoneySplitTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/TaxKit/Money/Money+Split.swift Tests/TaxKitTests/MoneySplitTests.swift
git commit -m "feat: add largest-remainder money splitting"
```

---

### Task 4: The single money formatter

**Files:**
- Create: `Sources/TaxKit/Money/Money+Formatting.swift`
- Test: `Tests/TaxKitTests/MoneyFormattingTests.swift`

**Interfaces:**
- Consumes: `Money` from Task 1.
- Produces: `Money.formatted() -> String` producing `RM 2,500.00`, and
  `Money.formattedCompact() -> String` producing `RM 2,500` for progress rows where the
  sen are noise. Every amount displayed anywhere in the app goes through one of these.

Note this does **not** use `.currency(code: "MYR")`. The locale-derived currency format
varies by OS release in spacing and symbol placement, which would make the output
untestable and inconsistent across the four platforms. The prefix is explicit; only the
digit grouping is delegated to the locale.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxKitTests/MoneyFormattingTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("Money formatting") struct MoneyFormattingTests {

    @Test("formats with an RM prefix, comma grouping and two decimals")
    func standardFormat() {
        #expect(Money(sen: 250_000).formatted() == "RM 2,500.00")
        #expect(Money(sen: 15_200).formatted()  == "RM 152.00")
        #expect(Money(sen: 5).formatted()       == "RM 0.05")
        #expect(Money.zero.formatted()          == "RM 0.00")
    }

    @Test("groups thousands and millions")
    func grouping() {
        #expect(Money(sen: 100_000_000).formatted() == "RM 1,000,000.00")
    }

    @Test("negatives put the sign before the prefix")
    func negatives() {
        #expect(Money(sen: -15_200).formatted() == "-RM 152.00")
    }

    @Test("the compact form drops the sen")
    func compact() {
        #expect(Money(sen: 250_000).formattedCompact() == "RM 2,500")
        #expect(Money(sen: 250_050).formattedCompact() == "RM 2,501")   // rounds half-up
        #expect(Money(sen: -250_000).formattedCompact() == "-RM 2,500")
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter MoneyFormattingTests`
Expected: FAIL — `value of type 'Money' has no member 'formatted'`.

- [ ] **Step 3: Implement the formatters**

Create `Sources/TaxKit/Money/Money+Formatting.swift`:

```swift
import Foundation

extension Money {

    /// The single display format for money in this app: `RM 2,500.00`.
    ///
    /// The `RM ` prefix is explicit rather than locale-derived, because the currency
    /// style's spacing and symbol placement drift between OS releases and would differ
    /// across iOS, macOS and watchOS. Only digit grouping is delegated to the locale.
    public func formatted() -> String {
        format(fractionDigits: 2)
    }

    /// `RM 2,500` — for progress rows where the sen are visual noise. Rounds half-up.
    public func formattedCompact() -> String {
        format(fractionDigits: 0)
    }

    private func format(fractionDigits: Int) -> String {
        let magnitude = Decimal(abs(sen)) / 100
        let digits = magnitude.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .grouping(.automatic)
                .rounded(rule: .toNearestOrAwayFromZero)
                .locale(Locale(identifier: "en_MY"))
        )
        return sen < 0 ? "-RM \(digits)" : "RM \(digits)"
    }
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `swift test --filter MoneyFormattingTests`
Expected: PASS, 4 tests.

If `formattedCompact` returns `RM 2,500` but the rounding assertion fails, check that
`.rounded(rule: .toNearestOrAwayFromZero)` is applied — the default is
`.toNearestOrEven`, which would give `RM 2,500` for `250_050`.

- [ ] **Step 5: Commit**

```bash
git add Sources/TaxKit/Money/Money+Formatting.swift Tests/TaxKitTests/MoneyFormattingTests.swift
git commit -m "feat: add the single ms_MY money formatter"
```

---

### Task 5: `ReliefCode`, its generator, and the staleness test

**Files:**
- Create: `Sources/TaxKit/Rules/ReliefCode.swift`
- Create: `Sources/TaxKit/Rules/ReliefCode+Generated.swift` (written by the generator)
- Create: `Sources/ReliefCodeGenerator/main.swift`
- Create: `Plugins/GenerateReliefCodes/plugin.swift`
- Modify: `Package.swift` (add the executable target and the plugin)
- Test: `Tests/TaxKitTests/ReliefCodeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ReliefCode` — `init(_ rawValue: String)`, `var rawValue: String`,
  `static let lifestyle`, `.medicalSerious`, and one constant per code in the rulebook.
  Conforms to `RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible`.
  Also `ReliefCode.allGenerated: [ReliefCode]` for the integrity tests in Task 9.

The generated constants come from the rulebook JSON written in Tasks 8 and 9. This task
builds the machinery and seeds it with the two codes the tests need; Task 9 regenerates it
against the full rulebook and the staleness test starts guarding it for real.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxKitTests/ReliefCodeTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("ReliefCode") struct ReliefCodeTests {

    @Test("wraps a raw string without altering it")
    func wrapsRawValue() {
        #expect(ReliefCode("LIFESTYLE").rawValue == "LIFESTYLE")
        #expect(ReliefCode(rawValue: "LIFESTYLE") == ReliefCode("LIFESTYLE"))
    }

    @Test("named constants match their raw values")
    func namedConstants() {
        #expect(ReliefCode.lifestyle.rawValue == "LIFESTYLE")
        #expect(ReliefCode.medicalSerious.rawValue == "MEDICAL_SERIOUS")
    }

    @Test("encodes as a bare string, not an object")
    func encodesAsString() throws {
        let data = try JSONEncoder().encode(ReliefCode.lifestyle)
        #expect(String(data: data, encoding: .utf8) == "\"LIFESTYLE\"")
        #expect(try JSONDecoder().decode(ReliefCode.self, from: data) == .lifestyle)
    }

    @Test("allGenerated lists every constant exactly once")
    func allGeneratedIsUnique() {
        let raws = ReliefCode.allGenerated.map(\.rawValue)
        #expect(raws.count == Set(raws).count)
        #expect(raws.contains("LIFESTYLE"))
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter ReliefCodeTests`
Expected: FAIL — `cannot find 'ReliefCode' in scope`.

- [ ] **Step 3: Implement the hand-written core type**

Create `Sources/TaxKit/Rules/ReliefCode.swift`:

```swift
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
```

- [ ] **Step 4: Seed the generated file by hand**

Create `Sources/TaxKit/Rules/ReliefCode+Generated.swift`. The generator will overwrite
this in Task 9 with the full set; the header and shape must match exactly what the
generator emits, or the staleness test will fail.

```swift
// Generated by `swift package generate-relief-codes`. Do not edit by hand.
// Source: Sources/TaxKit/Resources/Rules/*.json

extension ReliefCode {

    public static let lifestyle = ReliefCode("LIFESTYLE")
    public static let medicalSerious = ReliefCode("MEDICAL_SERIOUS")

    /// Every code declared in the shipped rulebooks, in sorted raw-value order.
    public static let allGenerated: [ReliefCode] = [
        .lifestyle,
        .medicalSerious,
    ]
}
```

- [ ] **Step 5: Run the test and confirm it passes**

Run: `swift test --filter ReliefCodeTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Write the generator executable**

Create `Sources/ReliefCodeGenerator/main.swift`:

```swift
import Foundation

// Usage: ReliefCodeGenerator <rules-directory> <output-file>
//
// Reads every ya-*.json, collects the union of relief codes including nested children
// and retired aliases, and writes ReliefCode+Generated.swift.

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("usage: ReliefCodeGenerator <rules-dir> <output-file>\n".utf8))
    exit(2)
}

let rulesDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let outputFile = URL(fileURLWithPath: CommandLine.arguments[2])

/// Minimal mirrors of the rulebook shape — the generator must not depend on TaxKit,
/// because TaxKit is what it generates into.
struct RawRelief: Decodable {
    let code: String
    let children: [RawRelief]?
}
struct RawRetirement: Decodable {
    let retired: String
}
struct RawRuleSet: Decodable {
    let reliefs: [RawRelief]
    let retiredCodes: [RawRetirement]?
}

func collect(_ reliefs: [RawRelief], into set: inout Set<String>) {
    for relief in reliefs {
        set.insert(relief.code)
        collect(relief.children ?? [], into: &set)
    }
}

var codes: Set<String> = []
let files = try FileManager.default
    .contentsOfDirectory(at: rulesDirectory, includingPropertiesForKeys: nil)
    .filter { $0.lastPathComponent.hasPrefix("ya-") && $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

for file in files {
    let ruleSet = try JSONDecoder().decode(RawRuleSet.self, from: try Data(contentsOf: file))
    collect(ruleSet.reliefs, into: &codes)
    for retirement in ruleSet.retiredCodes ?? [] { codes.insert(retirement.retired) }
}

/// LIFESTYLE -> lifestyle, MEDICAL_SERIOUS -> medicalSerious
func swiftIdentifier(for code: String) -> String {
    let parts = code.split(separator: "_").map { $0.lowercased() }
    guard let first = parts.first else { return code.lowercased() }
    return ([first] + parts.dropFirst().map(\.capitalized)).joined()
}

let sorted = codes.sorted()
var out = """
// Generated by `swift package generate-relief-codes`. Do not edit by hand.
// Source: Sources/TaxKit/Resources/Rules/*.json

extension ReliefCode {


"""
for code in sorted {
    out += "    public static let \(swiftIdentifier(for: code)) = ReliefCode(\"\(code)\")\n"
}
out += """

    /// Every code declared in the shipped rulebooks, in sorted raw-value order.
    public static let allGenerated: [ReliefCode] = [

"""
for code in sorted {
    out += "        .\(swiftIdentifier(for: code)),\n"
}
out += """
    ]
}

"""

try out.write(to: outputFile, atomically: true, encoding: .utf8)
print("Wrote \(sorted.count) relief codes to \(outputFile.path)")
```

- [ ] **Step 7: Write the command plugin**

Create `Plugins/GenerateReliefCodes/plugin.swift`:

```swift
import PackagePlugin
import Foundation

@main
struct GenerateReliefCodes: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let generator = try context.tool(named: "ReliefCodeGenerator")
        let rules = context.package.directoryURL
            .appending(path: "Sources/TaxKit/Resources/Rules")
        let output = context.package.directoryURL
            .appending(path: "Sources/TaxKit/Rules/ReliefCode+Generated.swift")

        let process = Process()
        process.executableURL = generator.url
        process.arguments = [rules.path(), output.path()]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            Diagnostics.error("ReliefCodeGenerator failed with status \(process.terminationStatus)")
            return
        }
    }
}
```

- [ ] **Step 8: Register the target and plugin in `Package.swift`**

Add to the `targets:` array, after the `TaxKit` target:

```swift
        .executableTarget(
            name: "ReliefCodeGenerator",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .plugin(
            name: "GenerateReliefCodes",
            capability: .command(
                intent: .custom(
                    verb: "generate-relief-codes",
                    description: "Regenerate ReliefCode constants from the rulebook JSON"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Writes Sources/TaxKit/Rules/ReliefCode+Generated.swift")
                ]
            ),
            dependencies: ["ReliefCodeGenerator"]
        ),
```

- [ ] **Step 9: Verify the plugin runs**

Run: `swift package --allow-writing-to-package-directory generate-relief-codes`
Expected: `Wrote 0 relief codes to .../ReliefCode+Generated.swift` — zero, because the
rulebook JSON does not exist yet. **Do not commit this empty output.** Restore the
hand-seeded file before committing:

```bash
git checkout Sources/TaxKit/Rules/ReliefCode+Generated.swift
swift test --filter ReliefCodeTests
```

Expected: PASS, 4 tests. Task 9 runs the generator against the real rulebook and commits
its output.

- [ ] **Step 10: Commit**

```bash
git add Package.swift Sources/TaxKit/Rules Sources/ReliefCodeGenerator Plugins Tests/TaxKitTests/ReliefCodeTests.swift
git commit -m "feat: add ReliefCode with a command-plugin generator"
```

---

### Task 6: The rulebook data model

**Files:**
- Create: `Sources/TaxKit/Rules/DocumentKind.swift`
- Create: `Sources/TaxKit/Rules/Cap.swift`
- Create: `Sources/TaxKit/Rules/ReliefRule.swift`
- Create: `Sources/TaxKit/Rules/RuleSet.swift`
- Create: `Sources/TaxKit/Engine/BracketTable.swift` (data only; behaviour in Task 10)
- Test: `Tests/TaxKitTests/RuleSetDecodingTests.swift`

**Interfaces:**
- Consumes: `Money` (Task 1), `ReliefCode` (Task 5).
- Produces:
  - `DocumentKind` — `.officialReceipt`, `.taxInvoice`, `.eInvoice`, `.medicalCertificate`,
    `.referralLetter`, `.insuranceStatement`, `.epfStatement`, `.bankStatement`, `.other`.
  - `Cap` — `.fixed(Money)`, `.perDependent(Money)`,
    `.tiered(on: TieredFact, tiers: [Tier])`; plus `Tier`, `TieredFact`.
  - `ReliefRule` — `code`, `name`, `cap`, `automatic`, `requiredDocuments`, `children`,
    `sourceURL`, `unverified`, `notes`. Task 7 adds the `eligibility` property.
  - `RuleSet` — `yearOfAssessment`, `revision`, `verifiedOn`, `sourceURL`, `brackets`,
    `reliefs`, `retiredCodes`; plus `Retirement`.
  - `BracketTable` — `bands: [Band]`; `Band` — `lowerBound`, `upperBound`, `rate`,
    `cumulativeBase`.
  - `RuleSet.allReliefs` — a depth-first flattening including nested children.

**Critical:** rates are decoded from JSON **strings**, never JSON numbers.
`JSONDecoder` routes a JSON number into `Decimal` via `Double`, which reintroduces exactly
the binary-floating-point error this design exists to avoid. `"rate": "0.19"` is correct;
`"rate": 0.19` is a defect. The same applies to every money field, which is why money is
carried as an integer `...Sen` key.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxKitTests/RuleSetDecodingTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("RuleSet decoding") struct RuleSetDecodingTests {

    static let sample = """
    {
      "yearOfAssessment": 2025,
      "revision": 1,
      "verifiedOn": "2026-08-23",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/",
      "brackets": {
        "bands": [
          { "lowerSen": 0,       "upperSen": 500000,  "rate": "0",    "cumulativeBaseSen": 0 },
          { "lowerSen": 500000,  "upperSen": 2000000, "rate": "0.01", "cumulativeBaseSen": 0 },
          { "lowerSen": 200000000,               "rate": "0.30", "cumulativeBaseSen": 52840000 }
        ]
      },
      "reliefs": [
        {
          "code": "MEDICAL_SERIOUS",
          "name": "Medical - serious illness",
          "cap": { "kind": "fixed", "sen": 1000000 },
          "requiredDocuments": ["officialReceipt", "medicalCertificate"],
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/",
          "children": [
            {
              "code": "MEDICAL_DENTAL",
              "name": "Dental examination and treatment",
              "cap": { "kind": "fixed", "sen": 100000 },
              "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/"
            }
          ]
        },
        {
          "code": "CHILD_UNDER_18",
          "name": "Child under 18",
          "cap": { "kind": "perDependent", "sen": 200000 },
      "automatic": true,
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/"
        },
        {
          "code": "HOUSING_LOAN_INTEREST",
          "name": "Housing loan interest, first home",
          "cap": {
            "kind": "tiered",
            "on": "propertyPrice",
            "tiers": [
              { "maxSen": 50000000, "sen": 700000 },
              { "maxSen": 75000000, "sen": 500000 }
            ]
          },
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/",
          "unverified": false
        }
      ],
      "retiredCodes": [
        { "retired": "BOOKS", "supersededBy": "LIFESTYLE", "fromYA": 2021 }
      ]
    }
    """

    func decoded() throws -> RuleSet {
        try JSONDecoder().decode(RuleSet.self, from: Data(Self.sample.utf8))
    }

    @Test("decodes the ruleset header")
    func header() throws {
        let rules = try decoded()
        #expect(rules.yearOfAssessment == 2025)
        #expect(rules.revision == 1)
        #expect(rules.verifiedOn == "2026-08-23")
        #expect(rules.verifiedOnDate != nil)
    }

    @Test("decodes rates from strings without floating-point error")
    func ratesAreExact() throws {
        let bands = try decoded().brackets.bands
        #expect(bands.count == 3)
        #expect(bands[1].rate == Decimal(string: "0.01")!)
        #expect(bands[0].lowerBound == Money.zero)
        #expect(bands[0].upperBound == Money(sen: 500_000))
        #expect(bands[2].upperBound == nil)
        #expect(bands[2].cumulativeBase == Money(sen: 52_840_000))
    }

    @Test("decodes every cap kind")
    func capKinds() throws {
        let reliefs = try decoded().reliefs
        #expect(reliefs[0].cap == .fixed(Money(sen: 1_000_000)))
        #expect(reliefs[1].cap == .perDependent(Money(sen: 200_000)))
        #expect(reliefs[2].cap == .tiered(on: .propertyPrice, tiers: [
            Tier(maxSen: 50_000_000, amount: Money(sen: 700_000)),
            Tier(maxSen: 75_000_000, amount: Money(sen: 500_000))
        ]))
    }

    @Test("omitted optional keys take safe defaults")
    func defaults() throws {
        let child = try decoded().reliefs[0].children[0]
        #expect(child.requiredDocuments.isEmpty)
        #expect(child.children.isEmpty)
        #expect(child.unverified == false)
        #expect(child.automatic == false)
    }

    @Test("required documents decode as typed kinds")
    func documentKinds() throws {
        #expect(try decoded().reliefs[0].requiredDocuments == [.officialReceipt, .medicalCertificate])
    }

    @Test("allReliefs flattens children depth-first")
    func flattening() throws {
        let codes = try decoded().allReliefs.map(\.code.rawValue)
        #expect(codes == ["MEDICAL_SERIOUS", "MEDICAL_DENTAL",
                          "CHILD_UNDER_18", "HOUSING_LOAN_INTEREST"])
    }

    @Test("retired codes decode with their successor")
    func retirements() throws {
        let retired = try decoded().retiredCodes
        #expect(retired.count == 1)
        #expect(retired[0].retired == ReliefCode("BOOKS"))
        #expect(retired[0].supersededBy == ReliefCode("LIFESTYLE"))
        #expect(retired[0].fromYA == 2021)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter RuleSetDecodingTests`
Expected: FAIL — `cannot find 'RuleSet' in scope`.

- [ ] **Step 3: Implement `DocumentKind`**

Create `Sources/TaxKit/Rules/DocumentKind.swift`:

```swift
import Foundation

/// A kind of supporting document LHDN may require for a claim.
///
/// Requirement checking is a set difference between the kinds attached to an entry and
/// the kinds its relief declares, so these cases must stay in sync with the rulebook.
public enum DocumentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case officialReceipt
    case taxInvoice
    case eInvoice
    case medicalCertificate
    case referralLetter
    case insuranceStatement
    case epfStatement
    case bankStatement
    case other
}
```

- [ ] **Step 4: Implement `Cap`**

Create `Sources/TaxKit/Rules/Cap.swift`:

```swift
import Foundation

/// The fact a tiered cap is selected by.
public enum TieredFact: String, Codable, Hashable, Sendable {
    /// Purchase price of the residence, for housing loan interest relief.
    case propertyPrice
}

/// One step of a tiered cap. `maxSen` is the inclusive upper bound of the selecting
/// fact; `nil` means "and above".
public struct Tier: Codable, Hashable, Sendable {
    public let maxSen: Int?
    public let amount: Money

    public init(maxSen: Int?, amount: Money) {
        self.maxSen = maxSen
        self.amount = amount
    }

    private enum CodingKeys: String, CodingKey { case maxSen, sen }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.maxSen = try c.decodeIfPresent(Int.self, forKey: .maxSen)
        self.amount = Money(sen: try c.decode(Int.self, forKey: .sen))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(maxSen, forKey: .maxSen)
        try c.encode(amount.sen, forKey: .sen)
    }
}

/// How much of a relief may be claimed.
public enum Cap: Codable, Hashable, Sendable {
    /// A flat ceiling.
    case fixed(Money)
    /// A ceiling that applies once per eligible dependent.
    case perDependent(Money)
    /// A ceiling selected by a fact about the claim.
    case tiered(on: TieredFact, tiers: [Tier])

    private enum CodingKeys: String, CodingKey { case kind, sen, on, tiers }
    private enum Kind: String, Codable { case fixed, perDependent, tiered }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .fixed:
            self = .fixed(Money(sen: try c.decode(Int.self, forKey: .sen)))
        case .perDependent:
            self = .perDependent(Money(sen: try c.decode(Int.self, forKey: .sen)))
        case .tiered:
            self = .tiered(on: try c.decode(TieredFact.self, forKey: .on),
                           tiers: try c.decode([Tier].self, forKey: .tiers))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fixed(let amount):
            try c.encode(Kind.fixed, forKey: .kind)
            try c.encode(amount.sen, forKey: .sen)
        case .perDependent(let amount):
            try c.encode(Kind.perDependent, forKey: .kind)
            try c.encode(amount.sen, forKey: .sen)
        case .tiered(let fact, let tiers):
            try c.encode(Kind.tiered, forKey: .kind)
            try c.encode(fact, forKey: .on)
            try c.encode(tiers, forKey: .tiers)
        }
    }

    /// The largest amount this cap can ever allow, ignoring per-dependent multiplicity.
    /// Used for display and for ordering opportunities.
    public var nominalCeiling: Money {
        switch self {
        case .fixed(let amount), .perDependent(let amount):
            return amount
        case .tiered(_, let tiers):
            return tiers.map(\.amount).max() ?? .zero
        }
    }
}
```

- [ ] **Step 5: Implement `BracketTable` (data only)**

Create `Sources/TaxKit/Engine/BracketTable.swift`:

```swift
import Foundation

/// One income band. `cumulativeBase` is the total tax owed at exactly `lowerBound`,
/// taken verbatim from LHDN's published table rather than derived, so bracket tax is a
/// lookup plus one multiplication with no accumulated rounding error.
public struct Band: Codable, Hashable, Sendable {
    /// The income already taxed by the lower bands — LHDN's "the first 5,000".
    /// The rate applies to `chargeable - lowerBound`, so widths are clean ringgit
    /// amounts and no band is a sen too narrow.
    public let lowerBound: Money
    /// Inclusive. `nil` for the top band.
    public let upperBound: Money?
    /// A fraction: 19% is `0.19`. Decoded from a string to avoid Double.
    public let rate: Decimal
    public let cumulativeBase: Money

    public init(lowerBound: Money, upperBound: Money?, rate: Decimal, cumulativeBase: Money) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.rate = rate
        self.cumulativeBase = cumulativeBase
    }

    private enum CodingKeys: String, CodingKey { case lowerSen, upperSen, rate, cumulativeBaseSen }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.lowerBound = Money(sen: try c.decode(Int.self, forKey: .lowerSen))
        self.upperBound = try c.decodeIfPresent(Int.self, forKey: .upperSen).map(Money.init(sen:))
        self.cumulativeBase = Money(sen: try c.decode(Int.self, forKey: .cumulativeBaseSen))

        let raw = try c.decode(String.self, forKey: .rate)
        guard let rate = Decimal(string: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rate, in: c, debugDescription: "Rate '\(raw)' is not a decimal")
        }
        self.rate = rate
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lowerBound.sen, forKey: .lowerSen)
        try c.encodeIfPresent(upperBound?.sen, forKey: .upperSen)
        try c.encode("\(rate)", forKey: .rate)
        try c.encode(cumulativeBase.sen, forKey: .cumulativeBaseSen)
    }
}

/// The income tax bands for one Year of Assessment. Behaviour is added in Task 10.
public struct BracketTable: Codable, Hashable, Sendable {
    public let bands: [Band]

    public init(bands: [Band]) { self.bands = bands }
}
```

- [ ] **Step 6: Implement `ReliefRule` and `RuleSet`**

Create `Sources/TaxKit/Rules/ReliefRule.swift`:

```swift
import Foundation

/// One relief category, optionally containing sub-limits that draw on its own ceiling.
public struct ReliefRule: Codable, Hashable, Sendable {
    public let code: ReliefCode
    public let name: String
    public let cap: Cap
    /// Granted in full when eligible, with no entry and no receipt — LHDN gives every
    /// resident the RM 9,000 individual relief, and child and spouse reliefs follow from
    /// the household rather than from a purchase.
    public let automatic: Bool
    public let requiredDocuments: [DocumentKind]
    /// Sub-limits. A child's claims also count against this relief's cap.
    public let children: [ReliefRule]
    public let sourceURL: URL
    /// Set when a figure could not be verified against hasil.gov.my. Excluded from
    /// tax-saved maths and rendered with a "verify with LHDN" note.
    public let unverified: Bool
    public let notes: String?

    private enum CodingKeys: String, CodingKey {
        case code, name, cap, automatic, requiredDocuments, children, sourceURL, unverified, notes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try c.decode(ReliefCode.self, forKey: .code)
        self.name = try c.decode(String.self, forKey: .name)
        self.cap = try c.decode(Cap.self, forKey: .cap)
        self.automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        self.requiredDocuments = try c.decodeIfPresent([DocumentKind].self, forKey: .requiredDocuments) ?? []
        self.children = try c.decodeIfPresent([ReliefRule].self, forKey: .children) ?? []
        self.sourceURL = try c.decode(URL.self, forKey: .sourceURL)
        self.unverified = try c.decodeIfPresent(Bool.self, forKey: .unverified) ?? false
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}
```

Create `Sources/TaxKit/Rules/RuleSet.swift`:

```swift
import Foundation

/// A code that no longer exists, and what replaced it. Codes are never deleted, so an
/// entry logged years ago still resolves to something the user can act on.
public struct Retirement: Codable, Hashable, Sendable {
    public let retired: ReliefCode
    public let supersededBy: ReliefCode?
    public let fromYA: Int
}

/// The complete rulebook for one Year of Assessment.
public struct RuleSet: Codable, Hashable, Sendable {
    public let yearOfAssessment: Int
    /// Bumped whenever the figures change within the same YA.
    public let revision: Int
    /// ISO date, `YYYY-MM-DD`, on which these figures were last checked against LHDN.
    public let verifiedOn: String
    public let sourceURL: URL
    public let brackets: BracketTable
    public let reliefs: [ReliefRule]
    public let retiredCodes: [Retirement]

    private enum CodingKeys: String, CodingKey {
        case yearOfAssessment, revision, verifiedOn, sourceURL, brackets, reliefs, retiredCodes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.yearOfAssessment = try c.decode(Int.self, forKey: .yearOfAssessment)
        self.revision = try c.decode(Int.self, forKey: .revision)
        self.verifiedOn = try c.decode(String.self, forKey: .verifiedOn)
        self.sourceURL = try c.decode(URL.self, forKey: .sourceURL)
        self.brackets = try c.decode(BracketTable.self, forKey: .brackets)
        self.reliefs = try c.decode([ReliefRule].self, forKey: .reliefs)
        self.retiredCodes = try c.decodeIfPresent([Retirement].self, forKey: .retiredCodes) ?? []
    }

    /// Every relief including nested children, depth-first, parents before their children.
    public var allReliefs: [ReliefRule] {
        func flatten(_ rules: [ReliefRule]) -> [ReliefRule] {
            rules.flatMap { [$0] + flatten($0.children) }
        }
        return flatten(reliefs)
    }

    public func relief(for code: ReliefCode) -> ReliefRule? {
        allReliefs.first { $0.code == code }
    }

    public var verifiedOnDate: Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: verifiedOn)
    }
}
```

- [ ] **Step 7: Run the test and confirm it passes**

Run: `swift test --filter RuleSetDecodingTests`
Expected: PASS, 7 tests.

`ReliefRule` deliberately has no `eligibility` property yet — Task 7 builds the predicate
language and adds it. Rulesets that already carry an `eligibility` key decode fine here,
because unknown keys are ignored.

- [ ] **Step 8: Commit**

```bash
git add Sources/TaxKit/Rules Sources/TaxKit/Engine Tests/TaxKitTests/RuleSetDecodingTests.swift
git commit -m "feat: add rulebook data model with string-decoded rates"
```

---

### Task 7: The eligibility predicate language

**Files:**
- Create: `Sources/TaxKit/Rules/EligibilityFacts.swift`
- Create: `Sources/TaxKit/Rules/EligibilityPredicate.swift`
- Modify: `Sources/TaxKit/Rules/ReliefRule.swift` (add the `eligibility` property)
- Test: `Tests/TaxKitTests/EligibilityTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - Predicate cases include `selfIsDisabled(Bool)` and `spouseIsDisabled(Bool)`, which
    gate the disabled-person reliefs so they are not offered to every household.
  - Fact enums: `MaritalStatus` (`.single .married .divorced .widowed`),
    `AssessmentType` (`.separate .joint .combinedUnderSpouse`),
    `EmploymentType` (`.privateSector .publicServantPensionable .selfEmployed`),
    `Gender` (`.female .male .unspecified`),
    `Claimant` (`.individual` raw `"self"`, `.spouse .child .parent .grandparent`),
    `EducationLevel` (`.none .preTertiary .tertiaryLocal .tertiaryOverseas`).
  - `ClaimHistory` (`.unknown .neverClaimed .lastClaimed(yearsAgo:)`).
  - `ProfileQuestion` — the question to ask when a fact is missing.
  - `DependentFacts`, `Facts`.
  - `PredicateOutcome` (`.satisfied`, `.failed(reason:)`, `.unknown(missing:)`).
  - `EligibilityPredicate` with `func evaluate(_ facts: Facts) -> PredicateOutcome`.
  - `ReliefRule.eligibility: EligibilityPredicate?`.

**The three-valued logic is the point of this task.** A missing fact must produce
`.unknown`, never `.failed`. Treating "we never asked whether your spouse has income" as
"you are not eligible" silently costs the user RM 4,000. `.unknown` becomes the home
screen's *"answer 1 question to unlock RM 4,000"* prompt.

Combination follows Kleene logic:

| | `all` | `any` |
|---|---|---|
| any child failed | **failed** | keep looking |
| any child unknown (none failed) | **unknown** (union of questions) | **unknown** if none satisfied |
| any child satisfied | keep looking | **satisfied** |
| all children satisfied / none satisfied | **satisfied** | **failed** |

`not` swaps satisfied and failed; `.unknown` stays `.unknown`.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxKitTests/EligibilityTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("Eligibility") struct EligibilityTests {

    func facts(_ mutate: (inout Facts) -> Void = { _ in }) -> Facts {
        var f = Facts(yearOfAssessment: 2025)
        mutate(&f)
        return f
    }

    @Test("a known matching fact is satisfied")
    func knownMatch() {
        let p = EligibilityPredicate.maritalStatus(in: [.married])
        #expect(p.evaluate(facts { $0.maritalStatus = .married }) == .satisfied)
    }

    @Test("a known non-matching fact fails with a reason")
    func knownMismatch() {
        let p = EligibilityPredicate.maritalStatus(in: [.married])
        let outcome = p.evaluate(facts { $0.maritalStatus = .single })
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)"); return
        }
        #expect(reason.contains("married"))
    }

    @Test("a missing fact is unknown and names the question to ask")
    func missingFactIsUnknown() {
        let p = EligibilityPredicate.spouseHasIncome(false)
        #expect(p.evaluate(facts()) == .unknown(missing: [.spouseHasIncome]))
    }

    @Test("all: one failure fails the whole predicate even with unknowns present")
    func allShortCircuitsOnFailure() {
        let p = EligibilityPredicate.all([
            .maritalStatus(in: [.married]),
            .spouseHasIncome(false)
        ])
        let outcome = p.evaluate(facts { $0.maritalStatus = .single })
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)"); return
        }
    }

    @Test("all: unknowns accumulate when nothing has failed")
    func allAccumulatesUnknowns() {
        let p = EligibilityPredicate.all([
            .spouseHasIncome(false),
            .employmentType(in: [.publicServantPensionable])
        ])
        #expect(p.evaluate(facts()) == .unknown(missing: [.spouseHasIncome, .employmentType]))
    }

    @Test("any: one satisfied child satisfies the whole predicate")
    func anySatisfies() {
        let p = EligibilityPredicate.any([
            .maritalStatus(in: [.married]),
            .spouseHasIncome(false)
        ])
        #expect(p.evaluate(facts { $0.maritalStatus = .married }) == .satisfied)
    }

    @Test("any: all children failing fails the whole predicate")
    func anyFails() {
        let p = EligibilityPredicate.any([.maritalStatus(in: [.married])])
        guard case .failed = p.evaluate(facts { $0.maritalStatus = .single }) else {
            Issue.record("expected .failed"); return
        }
    }

    @Test("any: an unknown child outranks a failed sibling — the honest answer is ask, not no")
    func anyPrefersUnknownOverFailed() {
        let p = EligibilityPredicate.any([
            .maritalStatus(in: [.married]),   // fails: the taxpayer is single
            .spouseHasIncome(false)           // unknown: never asked
        ])
        // Collapsing this to .failed is the defect that silently costs RM 4,000.
        #expect(p.evaluate(facts { $0.maritalStatus = .single })
                == .unknown(missing: [.spouseHasIncome]))
    }

    @Test("all: a failed child outranks an unknown sibling accumulated before it")
    func allPrefersFailedOverUnknown() {
        let p = EligibilityPredicate.all([
            .spouseHasIncome(false),          // unknown, seen first
            .maritalStatus(in: [.married])    // fails: the taxpayer is single
        ])
        guard case .failed = p.evaluate(facts { $0.maritalStatus = .single }) else {
            Issue.record("expected .failed to win over an earlier unknown"); return
        }
    }

    @Test("not inverts satisfied and failed but preserves unknown")
    func notInverts() {
        let known = facts { $0.maritalStatus = .married }
        guard case .failed = EligibilityPredicate.not(.maritalStatus(in: [.married])).evaluate(known) else {
            Issue.record("expected .failed"); return
        }
        #expect(EligibilityPredicate.not(.spouseHasIncome(false)).evaluate(facts())
                == .unknown(missing: [.spouseHasIncome]))
    }

    @Test("dependent age bounds are inclusive")
    func dependentAgeBounds() {
        let p = EligibilityPredicate.dependentAge(min: nil, max: 18)
        #expect(p.evaluate(facts { $0.dependent = DependentFacts(ageAtYearEnd: 18) }) == .satisfied)
        guard case .failed = p.evaluate(facts { $0.dependent = DependentFacts(ageAtYearEnd: 19) }) else {
            Issue.record("expected .failed at 19"); return
        }
        #expect(p.evaluate(facts()) == .unknown(missing: [.dependentDetails]))
    }

    @Test("yaRange is evaluated against the ruleset year, which is always known")
    func yaRange() {
        let p = EligibilityPredicate.yaRange(from: 2025, to: 2027)
        #expect(p.evaluate(facts()) == .satisfied)
        var earlier = facts(); earlier.yearOfAssessment = 2024
        guard case .failed = p.evaluate(earlier) else {
            Issue.record("expected .failed for 2024"); return
        }
    }

    @Test("claim frequency: never claimed is satisfied, too recent fails, unknown asks")
    func claimFrequency() {
        let p = EligibilityPredicate.claimFrequency(everyNYears: 2)
        #expect(p.evaluate(facts { $0.claimHistory = .neverClaimed }) == .satisfied)
        #expect(p.evaluate(facts { $0.claimHistory = .lastClaimed(yearsAgo: 2) }) == .satisfied)
        guard case .failed = p.evaluate(facts { $0.claimHistory = .lastClaimed(yearsAgo: 1) }) else {
            Issue.record("expected .failed after 1 year"); return
        }
        #expect(p.evaluate(facts()) == .unknown(missing: [.lastClaimYear]))
    }

    @Test("round-trips through JSON")
    func codableRoundTrip() throws {
        let original = EligibilityPredicate.all([
            .maritalStatus(in: [.married, .divorced]),
            .not(.spouseHasIncome(true)),
            .any([.dependentAge(min: 18, max: nil), .dependentIsDisabled(true)]),
            .yaRange(from: 2025, to: nil),
            .claimant(in: [.individual, .spouse, .child])
        ])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(EligibilityPredicate.self, from: data) == original)
    }

    @Test("every predicate case survives a JSON round trip")
    func everyCaseRoundTrips() throws {
        let cases: [EligibilityPredicate] = [
            .always,
            .maritalStatus(in: [.single, .widowed]),
            .spouseHasIncome(true),
            .assessmentType(.combinedUnderSpouse),
            .employmentType(in: [.selfEmployed, .publicServantPensionable]),
            .gender(.female),
            .selfIsDisabled(true),
            .spouseIsDisabled(false),
            .claimant(in: [.parent, .grandparent]),
            .dependentAge(min: 0, max: 6),
            .dependentEducation(in: [.tertiaryOverseas]),
            .dependentIsDisabled(true),
            .yaRange(from: nil, to: 2027),
            .claimFrequency(everyNYears: 2),
            .not(.always),
            .all([.always]),
            .any([.always])
        ]
        for original in cases {
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(EligibilityPredicate.self, from: data) == original,
                    "round trip failed for \(original)")
        }
    }

    @Test("decodes the wire format used in the rulebook JSON")
    func decodesWireFormat() throws {
        let json = """
        { "op": "all", "of": [
            { "op": "claimant", "in": ["self", "spouse", "child"] },
            { "op": "dependentAge", "max": 18 }
        ] }
        """
        let decoded = try JSONDecoder().decode(EligibilityPredicate.self, from: Data(json.utf8))
        #expect(decoded == .all([
            .claimant(in: [.individual, .spouse, .child]),
            .dependentAge(min: nil, max: 18)
        ]))
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter EligibilityTests`
Expected: FAIL — `cannot find 'Facts' in scope`.

- [ ] **Step 3: Implement the fact types**

Create `Sources/TaxKit/Rules/EligibilityFacts.swift`:

```swift
import Foundation

public enum MaritalStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case single, married, divorced, widowed
}

public enum AssessmentType: String, Codable, Hashable, Sendable, CaseIterable {
    case separate, joint, combinedUnderSpouse
}

public enum EmploymentType: String, Codable, Hashable, Sendable, CaseIterable {
    case privateSector, publicServantPensionable, selfEmployed
}

public enum Gender: String, Codable, Hashable, Sendable, CaseIterable {
    case female, male, unspecified
}

/// Who a claim is made in respect of.
public enum Claimant: String, Codable, Hashable, Sendable, CaseIterable {
    case individual = "self"
    case spouse, child, parent, grandparent
}

public enum EducationLevel: String, Codable, Hashable, Sendable, CaseIterable {
    case none, preTertiary, tertiaryLocal, tertiaryOverseas
}

/// Whether a once-every-N-years relief has been claimed before.
public enum ClaimHistory: Hashable, Sendable {
    case unknown
    case neverClaimed
    case lastClaimed(yearsAgo: Int)
}

/// A fact the app does not yet know, phrased as something to ask the user.
/// Each case maps to one prompt on the home screen and one topic for the assistant.
public enum ProfileQuestion: String, Codable, Hashable, Sendable, CaseIterable {
    case maritalStatus
    case spouseHasIncome
    case assessmentType
    case employmentType
    case gender
    case dependentDetails
    case lastClaimYear
    case propertyPrice
    case disabilityStatus
    case spouseDisabilityStatus
}

public struct DependentFacts: Hashable, Sendable {
    public var ageAtYearEnd: Int?
    public var educationLevel: EducationLevel?
    public var isDisabled: Bool?

    public init(ageAtYearEnd: Int? = nil,
                educationLevel: EducationLevel? = nil,
                isDisabled: Bool? = nil) {
        self.ageAtYearEnd = ageAtYearEnd
        self.educationLevel = educationLevel
        self.isDisabled = isDisabled
    }
}

/// Everything a predicate may ask about. `nil` means "not yet known", which produces
/// `.unknown` rather than a failure.
public struct Facts: Hashable, Sendable {
    public var yearOfAssessment: Int
    public var maritalStatus: MaritalStatus?
    public var spouseHasIncome: Bool?
    public var assessmentType: AssessmentType?
    public var employmentType: EmploymentType?
    public var gender: Gender?
    public var claimant: Claimant?
    public var dependent: DependentFacts?
    public var claimHistory: ClaimHistory
    public var propertyPriceSen: Int?
    /// Whether the taxpayer is a person with disabilities registered with JKM.
    public var selfIsDisabled: Bool?
    public var spouseIsDisabled: Bool?

    public init(yearOfAssessment: Int,
                maritalStatus: MaritalStatus? = nil,
                spouseHasIncome: Bool? = nil,
                assessmentType: AssessmentType? = nil,
                employmentType: EmploymentType? = nil,
                gender: Gender? = nil,
                claimant: Claimant? = nil,
                dependent: DependentFacts? = nil,
                claimHistory: ClaimHistory = .unknown,
                propertyPriceSen: Int? = nil,
                selfIsDisabled: Bool? = nil,
                spouseIsDisabled: Bool? = nil) {
        self.yearOfAssessment = yearOfAssessment
        self.maritalStatus = maritalStatus
        self.spouseHasIncome = spouseHasIncome
        self.assessmentType = assessmentType
        self.employmentType = employmentType
        self.gender = gender
        self.claimant = claimant
        self.dependent = dependent
        self.claimHistory = claimHistory
        self.propertyPriceSen = propertyPriceSen
        self.selfIsDisabled = selfIsDisabled
        self.spouseIsDisabled = spouseIsDisabled
    }
}

/// Three-valued, because "we have not asked yet" is not the same as "no".
public enum PredicateOutcome: Hashable, Sendable {
    case satisfied
    case failed(reason: String)
    case unknown(missing: [ProfileQuestion])
}
```

- [ ] **Step 4: Implement the predicate**

Create `Sources/TaxKit/Rules/EligibilityPredicate.swift`:

```swift
import Foundation

/// A closed, non-executable condition tree.
///
/// Deliberately not a scripting language: every case is enumerable in Swift, so the
/// rulebook can never do anything the engine has not been written and tested to handle.
public indirect enum EligibilityPredicate: Codable, Hashable, Sendable {
    case always
    case all([EligibilityPredicate])
    case any([EligibilityPredicate])
    case not(EligibilityPredicate)

    case maritalStatus(in: [MaritalStatus])
    case spouseHasIncome(Bool)
    case assessmentType(AssessmentType)
    case employmentType(in: [EmploymentType])
    case gender(Gender)
    case selfIsDisabled(Bool)
    case spouseIsDisabled(Bool)
    case claimant(in: [Claimant])
    case dependentAge(min: Int?, max: Int?)
    case dependentEducation(in: [EducationLevel])
    case dependentIsDisabled(Bool)
    case yaRange(from: Int?, to: Int?)
    case claimFrequency(everyNYears: Int)

    // MARK: Evaluation

    public func evaluate(_ facts: Facts) -> PredicateOutcome {
        switch self {
        case .always:
            return .satisfied

        case .all(let children):
            var missing: [ProfileQuestion] = []
            for child in children {
                switch child.evaluate(facts) {
                case .satisfied: continue
                case .failed(let reason): return .failed(reason: reason)
                case .unknown(let questions): missing.append(contentsOf: questions)
                }
            }
            return missing.isEmpty ? .satisfied : .unknown(missing: missing.deduplicated())

        case .any(let children):
            var missing: [ProfileQuestion] = []
            var reasons: [String] = []
            for child in children {
                switch child.evaluate(facts) {
                case .satisfied: return .satisfied
                case .failed(let reason): reasons.append(reason)
                case .unknown(let questions): missing.append(contentsOf: questions)
                }
            }
            if !missing.isEmpty { return .unknown(missing: missing.deduplicated()) }
            return .failed(reason: reasons.joined(separator: "; or "))

        case .not(let child):
            switch child.evaluate(facts) {
            case .satisfied: return .failed(reason: "Condition must not hold")
            case .failed: return .satisfied
            case .unknown(let questions): return .unknown(missing: questions)
            }

        case .maritalStatus(let allowed):
            return Self.check(facts.maritalStatus, in: allowed,
                              asking: .maritalStatus, label: "Marital status")

        case .spouseHasIncome(let required):
            return Self.check(facts.spouseHasIncome, equals: required,
                              asking: .spouseHasIncome,
                              label: required ? "Spouse must have income"
                                              : "Spouse must have no income")

        case .assessmentType(let required):
            return Self.check(facts.assessmentType, in: [required],
                              asking: .assessmentType, label: "Assessment type")

        case .employmentType(let allowed):
            return Self.check(facts.employmentType, in: allowed,
                              asking: .employmentType, label: "Employment type")

        case .gender(let required):
            return Self.check(facts.gender, in: [required],
                              asking: .gender, label: "Gender")

        case .selfIsDisabled(let required):
            return Self.check(facts.selfIsDisabled, equals: required,
                              asking: .disabilityStatus,
                              label: required ? "You must be a registered disabled person"
                                              : "You must not be registered disabled")

        case .spouseIsDisabled(let required):
            return Self.check(facts.spouseIsDisabled, equals: required,
                              asking: .spouseDisabilityStatus,
                              label: required ? "Spouse must be a registered disabled person"
                                              : "Spouse must not be registered disabled")

        case .claimant(let allowed):
            return Self.check(facts.claimant, in: allowed,
                              asking: .dependentDetails, label: "Claimed for")

        case .dependentAge(let min, let max):
            guard let age = facts.dependent?.ageAtYearEnd else {
                return .unknown(missing: [.dependentDetails])
            }
            if let min, age < min {
                return .failed(reason: "Dependent must be at least \(min) years old")
            }
            if let max, age > max {
                return .failed(reason: "Dependent must be \(max) years old or under")
            }
            return .satisfied

        case .dependentEducation(let allowed):
            return Self.check(facts.dependent?.educationLevel, in: allowed,
                              asking: .dependentDetails, label: "Education level")

        case .dependentIsDisabled(let required):
            return Self.check(facts.dependent?.isDisabled, equals: required,
                              asking: .dependentDetails,
                              label: required ? "Dependent must be disabled"
                                              : "Dependent must not be disabled")

        case .yaRange(let from, let to):
            let ya = facts.yearOfAssessment
            if let from, ya < from { return .failed(reason: "Not available before YA\(from)") }
            if let to, ya > to { return .failed(reason: "Not available after YA\(to)") }
            return .satisfied

        case .claimFrequency(let everyNYears):
            switch facts.claimHistory {
            case .unknown:
                return .unknown(missing: [.lastClaimYear])
            case .neverClaimed:
                return .satisfied
            case .lastClaimed(let yearsAgo):
                return yearsAgo >= everyNYears
                    ? .satisfied
                    : .failed(reason: "Claimable once every \(everyNYears) years of assessment")
            }
        }
    }

    private static func check<T: Equatable>(_ value: T?,
                                            in allowed: [T],
                                            asking question: ProfileQuestion,
                                            label: String) -> PredicateOutcome {
        guard let value else { return .unknown(missing: [question]) }
        return allowed.contains(value)
            ? .satisfied
            : .failed(reason: "\(label) must be \(Self.describe(allowed))")
    }

    private static func check<T: Equatable>(_ value: T?,
                                            equals required: T,
                                            asking question: ProfileQuestion,
                                            label: String) -> PredicateOutcome {
        guard let value else { return .unknown(missing: [question]) }
        return value == required ? .satisfied : .failed(reason: label)
    }

    private static func describe<T>(_ allowed: [T]) -> String {
        let described = allowed.map { value -> String in
            (value as? any RawRepresentable).map { "\($0.rawValue)" } ?? "\(value)"
        }
        return described.joined(separator: " or ")
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case op, of, `in`, `is`, min, max, from, to, everyNYears
    }
    private enum Op: String, Codable {
        case always, all, any, not
        case maritalStatus, spouseHasIncome, assessmentType, employmentType, gender
        case selfIsDisabled, spouseIsDisabled
        case claimant, dependentAge, dependentEducation, dependentIsDisabled
        case yaRange, claimFrequency
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .always: self = .always
        case .all:    self = .all(try c.decode([EligibilityPredicate].self, forKey: .of))
        case .any:    self = .any(try c.decode([EligibilityPredicate].self, forKey: .of))
        case .not:
            let children = try c.decode([EligibilityPredicate].self, forKey: .of)
            guard children.count == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .of, in: c, debugDescription: "not takes exactly one operand")
            }
            self = .not(children[0])
        case .maritalStatus:
            self = .maritalStatus(in: try c.decode([MaritalStatus].self, forKey: .in))
        case .spouseHasIncome:
            self = .spouseHasIncome(try c.decode(Bool.self, forKey: .is))
        case .assessmentType:
            self = .assessmentType(try c.decode(AssessmentType.self, forKey: .is))
        case .employmentType:
            self = .employmentType(in: try c.decode([EmploymentType].self, forKey: .in))
        case .gender:
            self = .gender(try c.decode(Gender.self, forKey: .is))
        case .selfIsDisabled:
            self = .selfIsDisabled(try c.decode(Bool.self, forKey: .is))
        case .spouseIsDisabled:
            self = .spouseIsDisabled(try c.decode(Bool.self, forKey: .is))
        case .claimant:
            self = .claimant(in: try c.decode([Claimant].self, forKey: .in))
        case .dependentAge:
            self = .dependentAge(min: try c.decodeIfPresent(Int.self, forKey: .min),
                                 max: try c.decodeIfPresent(Int.self, forKey: .max))
        case .dependentEducation:
            self = .dependentEducation(in: try c.decode([EducationLevel].self, forKey: .in))
        case .dependentIsDisabled:
            self = .dependentIsDisabled(try c.decode(Bool.self, forKey: .is))
        case .yaRange:
            self = .yaRange(from: try c.decodeIfPresent(Int.self, forKey: .from),
                            to: try c.decodeIfPresent(Int.self, forKey: .to))
        case .claimFrequency:
            self = .claimFrequency(everyNYears: try c.decode(Int.self, forKey: .everyNYears))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .always:
            try c.encode(Op.always, forKey: .op)
        case .all(let children):
            try c.encode(Op.all, forKey: .op); try c.encode(children, forKey: .of)
        case .any(let children):
            try c.encode(Op.any, forKey: .op); try c.encode(children, forKey: .of)
        case .not(let child):
            try c.encode(Op.not, forKey: .op); try c.encode([child], forKey: .of)
        case .maritalStatus(let allowed):
            try c.encode(Op.maritalStatus, forKey: .op); try c.encode(allowed, forKey: .in)
        case .spouseHasIncome(let value):
            try c.encode(Op.spouseHasIncome, forKey: .op); try c.encode(value, forKey: .is)
        case .assessmentType(let value):
            try c.encode(Op.assessmentType, forKey: .op); try c.encode(value, forKey: .is)
        case .employmentType(let allowed):
            try c.encode(Op.employmentType, forKey: .op); try c.encode(allowed, forKey: .in)
        case .gender(let value):
            try c.encode(Op.gender, forKey: .op); try c.encode(value, forKey: .is)
        case .selfIsDisabled(let value):
            try c.encode(Op.selfIsDisabled, forKey: .op); try c.encode(value, forKey: .is)
        case .spouseIsDisabled(let value):
            try c.encode(Op.spouseIsDisabled, forKey: .op); try c.encode(value, forKey: .is)
        case .claimant(let allowed):
            try c.encode(Op.claimant, forKey: .op); try c.encode(allowed, forKey: .in)
        case .dependentAge(let min, let max):
            try c.encode(Op.dependentAge, forKey: .op)
            try c.encodeIfPresent(min, forKey: .min); try c.encodeIfPresent(max, forKey: .max)
        case .dependentEducation(let allowed):
            try c.encode(Op.dependentEducation, forKey: .op); try c.encode(allowed, forKey: .in)
        case .dependentIsDisabled(let value):
            try c.encode(Op.dependentIsDisabled, forKey: .op); try c.encode(value, forKey: .is)
        case .yaRange(let from, let to):
            try c.encode(Op.yaRange, forKey: .op)
            try c.encodeIfPresent(from, forKey: .from); try c.encodeIfPresent(to, forKey: .to)
        case .claimFrequency(let n):
            try c.encode(Op.claimFrequency, forKey: .op); try c.encode(n, forKey: .everyNYears)
        }
    }
}

extension Array where Element: Hashable {
    /// Order-preserving deduplication, so question lists stay stable for the UI.
    func deduplicated() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
```

- [ ] **Step 5: Add the property to `ReliefRule`**

In `Sources/TaxKit/Rules/ReliefRule.swift`, add the stored property after
`requiredDocuments`:

```swift
    public let eligibility: EligibilityPredicate?
```

add `eligibility` to `CodingKeys`:

```swift
        case code, name, cap, automatic, requiredDocuments, eligibility, children, sourceURL, unverified, notes
```

and decode it after `requiredDocuments`:

```swift
        self.eligibility = try c.decodeIfPresent(EligibilityPredicate.self, forKey: .eligibility)
```

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `swift test --filter EligibilityTests`
Expected: PASS, 13 tests.

Run: `swift test`
Expected: PASS, all suites — `RuleSetDecodingTests` still passes because `eligibility` is
optional and absent from that fixture.

- [ ] **Step 7: Commit**

```bash
git add Sources/TaxKit/Rules Tests/TaxKitTests/EligibilityTests.swift
git commit -m "feat: add three-valued eligibility predicate language"
```

---

### Task 8: The YA2025 rulebook

**Files:**
- Create: `Sources/TaxKit/Resources/Rules/ya-2025.json`
- Delete: `Sources/TaxKit/Resources/Rules/.keep.json`
- Test: `Tests/TaxKitTests/RulebookIntegrityTests.swift`

**Interfaces:**
- Consumes: `RuleSet` (Task 6), `EligibilityPredicate` (Task 7).
- Produces: the YA2025 ruleset resource and `RulebookIntegrityTests`, which every later
  ruleset must also satisfy.

Every figure below is transcribed from https://www.hasil.gov.my/individu/pelepasan-cukai/
and https://www.hasil.gov.my/individu/kadar-cukai/, retrieved 2026-08-23, and matches
spec §8. Do not adjust a figure without re-reading the source and updating `verifiedOn`.

Two modelling notes:

- **Life insurance and EPF** (LHDN item 17) is a RM 7,000 ceiling with a RM 4,000 EPF
  sub-limit and a RM 3,000 life/takaful sub-limit — a parent cap with two children. Parent
  and child caps are how every shared ceiling in the Malaysian rulebook is expressed, which
  is why `Cap` has no separate shared-pool case.
- **LHDN items 6, 7 and 8** are three rows that all draw on one RM 10,000 ceiling, so they
  are modelled as one parent (`MEDICAL_SERIOUS`) with four sub-limits.
- **Nine reliefs are `automatic`**: the individual RM 9,000, spouse/alimony, the two
  disabled-person reliefs, and the five child reliefs. LHDN grants these from the
  household rather than from a purchase, so the engine allows the full cap when the
  relief is eligible instead of waiting for an entry. The two disabled-person reliefs
  carry `selfIsDisabled` / `spouseIsDisabled` predicates so they are not handed to every
  household. `DISABLED_EQUIPMENT` stays entry-driven — it is an actual purchase.

- [ ] **Step 1: Write the failing integrity test**

Create `Tests/TaxKitTests/RulebookIntegrityTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("Rulebook integrity") struct RulebookIntegrityTests {

    /// Every YA shipped in the bundle. Extended in Task 9.
    static let shippedYears = [2025]

    static func load(_ year: Int) throws -> RuleSet {
        let url = try #require(
            Bundle.module.url(forResource: "ya-\(year)", withExtension: "json",
                              subdirectory: "Rules"),
            "ya-\(year).json is not in the bundle")
        return try JSONDecoder().decode(RuleSet.self, from: try Data(contentsOf: url))
    }

    @Test("every shipped year decodes", arguments: shippedYears)
    func decodes(year: Int) throws {
        #expect(try Self.load(year).yearOfAssessment == year)
    }

    @Test("verifiedOn is a real ISO date", arguments: shippedYears)
    func verifiedOnIsValid(year: Int) throws {
        let rules = try Self.load(year)
        #expect(rules.verifiedOn.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil)
        #expect(rules.verifiedOnDate != nil)
    }

    @Test("every relief cites an LHDN source", arguments: shippedYears)
    func everyReliefHasASource(year: Int) throws {
        for relief in try Self.load(year).allReliefs {
            #expect(relief.sourceURL.host()?.hasSuffix("hasil.gov.my") == true,
                    "\(relief.code) cites \(relief.sourceURL)")
        }
    }

    @Test("relief codes are unique within a year", arguments: shippedYears)
    func codesAreUnique(year: Int) throws {
        let codes = try Self.load(year).allReliefs.map(\.code.rawValue)
        #expect(codes.count == Set(codes).count)
    }

    @Test("no relief is left marked unverified", arguments: shippedYears)
    func nothingUnverified(year: Int) throws {
        let unverified = try Self.load(year).allReliefs.filter(\.unverified).map(\.code.rawValue)
        #expect(unverified.isEmpty, "unverified: \(unverified)")
    }

    @Test("sub-limits never exceed their parent's ceiling", arguments: shippedYears)
    func childCapsFitInsideParents(year: Int) throws {
        for parent in try Self.load(year).reliefs {
            for child in parent.children {
                #expect(child.cap.nominalCeiling <= parent.cap.nominalCeiling,
                        "\(child.code) exceeds \(parent.code)")
            }
        }
    }

    @Test("bands are contiguous, ascending, and only the last is open-ended",
          arguments: shippedYears)
    func bandsAreWellFormed(year: Int) throws {
        let bands = try Self.load(year).brackets.bands
        #expect(bands.first?.lowerBound == .zero)
        for (index, band) in bands.enumerated() {
            if index == bands.count - 1 {
                #expect(band.upperBound == nil, "the top band must be open-ended")
            } else {
                let upper = try #require(band.upperBound)
                #expect(upper == bands[index + 1].lowerBound,
                        "gap or overlap after band \(index)")
                #expect(band.rate <= bands[index + 1].rate, "rates must not decrease")
            }
        }
    }

    @Test("each band's cumulative base equals the previous base plus the previous band's tax",
          arguments: shippedYears)
    func cumulativeBasesAreConsistent(year: Int) throws {
        let bands = try Self.load(year).brackets.bands
        for index in 1..<bands.count {
            let previous = bands[index - 1]
            let width = try #require(previous.upperBound) - previous.lowerBound
            let expected = previous.cumulativeBase + width.applying(previous.rate)
            #expect(bands[index].cumulativeBase == expected,
                    "band \(index) base is \(bands[index].cumulativeBase.formatted()), "
                    + "expected \(expected.formatted())")
        }
    }

    @Test("YA2025 carries the reliefs LHDN publishes")
    func ya2025Spot() throws {
        let rules = try Self.load(2025)
        #expect(rules.relief(for: .lifestyle)?.cap == .fixed(Money(ringgit: 2500)))
        #expect(rules.relief(for: ReliefCode("DISABLED_SELF"))?.cap == .fixed(Money(ringgit: 7000)))
        #expect(rules.relief(for: ReliefCode("DISABLED_SPOUSE"))?.cap == .fixed(Money(ringgit: 6000)))
        #expect(rules.relief(for: ReliefCode("INSURANCE_EDU_MEDICAL"))?.cap == .fixed(Money(ringgit: 4000)))
        #expect(rules.relief(for: ReliefCode("MEDICAL_LEARNDIS"))?.cap == .fixed(Money(ringgit: 6000)))
        #expect(rules.relief(for: ReliefCode("SOCSO_EIS"))?.cap == .fixed(Money(ringgit: 350)))
        #expect(rules.relief(for: ReliefCode("HOUSING_LOAN_INTEREST")) != nil)
    }

    @Test("exactly the household-derived reliefs are automatic", arguments: shippedYears)
    func automaticSet(year: Int) throws {
        let automatic = Set(try Self.load(year).allReliefs
            .filter(\.automatic).map(\.code.rawValue))
        // The automatic set is identical in all three shipped years.
        #expect(automatic == [
            "SELF_AND_DEPENDENTS", "SPOUSE_ALIMONY", "DISABLED_SELF", "DISABLED_SPOUSE",
            "CHILD_UNDER_18", "CHILD_PRE_TERTIARY", "CHILD_TERTIARY",
            "CHILD_DISABLED", "CHILD_DISABLED_TERTIARY"
        ])
    }

    @Test("every automatic relief is gated or unconditional, never a free grant",
          arguments: shippedYears)
    func automaticRelievesAreGated(year: Int) throws {
        for relief in try Self.load(year).allReliefs where relief.automatic {
            let gated = relief.eligibility != nil
            let perDependent = if case .perDependent = relief.cap { true } else { false }
            let unconditional = relief.code == ReliefCode("SELF_AND_DEPENDENTS")
            #expect(gated || perDependent || unconditional,
                    "\(relief.code) is automatic with nothing gating it")
        }
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter RulebookIntegrityTests`
Expected: FAIL — `ya-2025.json is not in the bundle`.

- [ ] **Step 3: Write the ruleset**

Delete the placeholder and create `Sources/TaxKit/Resources/Rules/ya-2025.json`.
`SRC` below stands for `"https://www.hasil.gov.my/individu/pelepasan-cukai/"` — write the
full URL at every occurrence; JSON has no variables.

```json
{
  "yearOfAssessment": 2025,
  "revision": 1,
  "verifiedOn": "2026-08-23",
  "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/",
  "brackets": {
    "bands": [
      { "lowerSen": 0,         "upperSen": 500000,    "rate": "0",    "cumulativeBaseSen": 0 },
      { "lowerSen": 500000,    "upperSen": 2000000,   "rate": "0.01", "cumulativeBaseSen": 0 },
      { "lowerSen": 2000000,   "upperSen": 3500000,   "rate": "0.03", "cumulativeBaseSen": 15000 },
      { "lowerSen": 3500000,   "upperSen": 5000000,   "rate": "0.06", "cumulativeBaseSen": 60000 },
      { "lowerSen": 5000000,   "upperSen": 7000000,   "rate": "0.11", "cumulativeBaseSen": 150000 },
      { "lowerSen": 7000000,   "upperSen": 10000000,  "rate": "0.19", "cumulativeBaseSen": 370000 },
      { "lowerSen": 10000000,  "upperSen": 40000000,  "rate": "0.25", "cumulativeBaseSen": 940000 },
      { "lowerSen": 40000000,  "upperSen": 60000000,  "rate": "0.26", "cumulativeBaseSen": 8440000 },
      { "lowerSen": 60000000,  "upperSen": 200000000, "rate": "0.28", "cumulativeBaseSen": 13640000 },
      { "lowerSen": 200000000,                        "rate": "0.30", "cumulativeBaseSen": 52840000 }
    ]
  },
  "reliefs": [
    { "code": "SELF_AND_DEPENDENTS", "name": "Individual and dependent relatives",
      "cap": { "kind": "fixed", "sen": 900000 },
      "automatic": true,
      "notes": "Granted to every resident individual without a claim.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "PARENTS_MEDICAL",
      "name": "Parents and grandparents — medical, dental, special needs, carer",
      "cap": { "kind": "fixed", "sen": 800000 },
      "requiredDocuments": ["officialReceipt", "medicalCertificate"],
      "eligibility": { "op": "claimant", "in": ["parent", "grandparent"] },
      "notes": "Health condition must be certified by a medical practitioner.",
      "children": [
        { "code": "PARENTS_CHECKUP", "name": "Parents — full medical check-up",
          "cap": { "kind": "fixed", "sen": 100000 },
          "requiredDocuments": ["officialReceipt"],
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" }
      ],
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "DISABLED_EQUIPMENT",
      "name": "Basic supporting equipment for a disabled self, spouse, child or parent",
      "cap": { "kind": "fixed", "sen": 600000 },
      "requiredDocuments": ["officialReceipt"],
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "DISABLED_SELF", "name": "Disabled individual",
      "cap": { "kind": "fixed", "sen": 700000 },
      "automatic": true,
      "eligibility": { "op": "selfIsDisabled", "is": true },
      "notes": "Requires JKM registration. YA2024 was RM 6,000.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "EDUCATION_SELF", "name": "Education fees (self)",
      "cap": { "kind": "fixed", "sen": 700000 },
      "requiredDocuments": ["officialReceipt"],
      "notes": "Law, accounting, Islamic finance, technical, vocational, industrial, scientific or technological at below master's level; any field at master's or doctoral level.",
      "children": [
        { "code": "EDUCATION_UPSKILL", "name": "Upskilling and self-enhancement courses",
          "cap": { "kind": "fixed", "sen": 200000 },
          "requiredDocuments": ["officialReceipt"],
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" }
      ],
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "MEDICAL_SERIOUS",
      "name": "Medical — serious illness, fertility treatment, vaccination, dental",
      "cap": { "kind": "fixed", "sen": 1000000 },
      "requiredDocuments": ["officialReceipt", "medicalCertificate"],
      "eligibility": { "op": "claimant", "in": ["self", "spouse", "child"] },
      "children": [
        { "code": "MEDICAL_VACCINATION", "name": "Vaccination",
          "cap": { "kind": "fixed", "sen": 100000 },
          "requiredDocuments": ["officialReceipt"],
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },
        { "code": "MEDICAL_DENTAL", "name": "Dental examination and treatment",
          "cap": { "kind": "fixed", "sen": 100000 },
          "requiredDocuments": ["officialReceipt"],
          "notes": "New in YA2024; absent from YA2023.",
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },
        { "code": "MEDICAL_CHECKUP",
          "name": "Full check-up, COVID-19 test, mental health, self-test kit, disease-detection fee",
          "cap": { "kind": "fixed", "sen": 100000 },
          "requiredDocuments": ["officialReceipt"],
          "notes": "YA2025 broadens this to self health-check equipment and disease-detection test fees.",
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },
        { "code": "MEDICAL_LEARNDIS",
          "name": "Learning disability diagnosis and early intervention, child 18 and under",
          "cap": { "kind": "fixed", "sen": 600000 },
          "requiredDocuments": ["officialReceipt", "medicalCertificate"],
          "eligibility": { "op": "dependentAge", "max": 18 },
          "notes": "YA2024 sub-limit was RM 4,000.",
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" }
      ],
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "LIFESTYLE",
      "name": "Lifestyle — books, computer, smartphone, tablet, internet, courses",
      "cap": { "kind": "fixed", "sen": 250000 },
      "requiredDocuments": ["officialReceipt"],
      "eligibility": { "op": "claimant", "in": ["self", "spouse", "child"] },
      "notes": "Not for business use. Internet must be billed in the claimant's own name.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "LIFESTYLE_SPORTS",
      "name": "Lifestyle additional — sports equipment, facilities, competitions, gym",
      "cap": { "kind": "fixed", "sen": 100000 },
      "requiredDocuments": ["officialReceipt"],
      "eligibility": { "op": "claimant", "in": ["self", "spouse", "child", "parent"] },
      "notes": "Sports Development Act 1997. YA2025 extends this to parents.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "BREASTFEEDING", "name": "Breastfeeding equipment",
      "cap": { "kind": "fixed", "sen": 100000 },
      "requiredDocuments": ["officialReceipt"],
      "eligibility": { "op": "all", "of": [
        { "op": "gender", "is": "female" },
        { "op": "dependentAge", "max": 2 },
        { "op": "claimFrequency", "everyNYears": 2 }
      ] },
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "CHILDCARE", "name": "Childcare centre or kindergarten fees",
      "cap": { "kind": "fixed", "sen": 300000 },
      "requiredDocuments": ["officialReceipt"],
      "eligibility": { "op": "dependentAge", "max": 6 },
      "notes": "Centre must be registered.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "SSPN", "name": "SSPN net deposit",
      "cap": { "kind": "fixed", "sen": 800000 },
      "requiredDocuments": ["bankStatement"],
      "notes": "Deposits in the year minus withdrawals in the year.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "SPOUSE_ALIMONY", "name": "Spouse, or alimony to a former wife",
      "cap": { "kind": "fixed", "sen": 400000 },
      "automatic": true,
      "eligibility": { "op": "any", "of": [
        { "op": "spouseHasIncome", "is": false },
        { "op": "assessmentType", "is": "joint" }
      ] },
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "DISABLED_SPOUSE", "name": "Disabled spouse",
      "cap": { "kind": "fixed", "sen": 600000 },
      "automatic": true,
      "eligibility": { "op": "spouseIsDisabled", "is": true },
      "notes": "Requires JKM registration. YA2024 was RM 5,000.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "CHILD_UNDER_18", "name": "Child under 18",
      "cap": { "kind": "perDependent", "sen": 200000 },
      "eligibility": { "op": "all", "of": [
        { "op": "claimant", "in": ["child"] },
        { "op": "dependentAge", "max": 17 }
      ] },
      "notes": "Splittable 50/50 between parents.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "CHILD_PRE_TERTIARY",
      "name": "Child 18 and over in full-time A-Level, matriculation or pre-degree study",
      "cap": { "kind": "perDependent", "sen": 200000 },
      "automatic": true,
      "eligibility": { "op": "all", "of": [
        { "op": "claimant", "in": ["child"] },
        { "op": "dependentAge", "min": 18 },
        { "op": "dependentEducation", "in": ["preTertiary"] }
      ] },
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "CHILD_TERTIARY",
      "name": "Child 18 and over in full-time tertiary study",
      "cap": { "kind": "perDependent", "sen": 800000 },
      "automatic": true,
      "eligibility": { "op": "all", "of": [
        { "op": "claimant", "in": ["child"] },
        { "op": "dependentAge", "min": 18 },
        { "op": "dependentEducation", "in": ["tertiaryLocal", "tertiaryOverseas"] }
      ] },
      "notes": "Local diploma and above, or overseas degree and above, at a recognised institution. Excludes matriculation, pre-degree and A-Level.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "CHILD_DISABLED", "name": "Disabled child",
      "cap": { "kind": "perDependent", "sen": 800000 },
      "automatic": true,
      "eligibility": { "op": "all", "of": [
        { "op": "claimant", "in": ["child"] },
        { "op": "dependentIsDisabled", "is": true }
      ] },
      "notes": "YA2024 was RM 6,000.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "CHILD_DISABLED_TERTIARY",
      "name": "Disabled child 18 and over in recognised tertiary study",
      "cap": { "kind": "perDependent", "sen": 800000 },
      "automatic": true,
      "eligibility": { "op": "all", "of": [
        { "op": "claimant", "in": ["child"] },
        { "op": "dependentIsDisabled", "is": true },
        { "op": "dependentAge", "min": 18 },
        { "op": "dependentEducation", "in": ["tertiaryLocal", "tertiaryOverseas"] }
      ] },
      "notes": "Claimed on top of CHILD_DISABLED.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "INSURANCE_LIFE_EPF", "name": "Life insurance and EPF",
      "cap": { "kind": "fixed", "sen": 700000 },
      "children": [
        { "code": "EPF_CONTRIBUTION",
          "name": "Approved scheme or EPF contributions",
          "cap": { "kind": "fixed", "sen": 400000 },
          "requiredDocuments": ["epfStatement"],
          "notes": "Excludes private retirement schemes.",
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },
        { "code": "LIFE_INSURANCE",
          "name": "Life insurance premiums, family takaful, additional voluntary EPF",
          "cap": { "kind": "fixed", "sen": 300000 },
          "requiredDocuments": ["insuranceStatement"],
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" }
      ],
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "PRS_ANNUITY", "name": "Private Retirement Scheme and deferred annuity",
      "cap": { "kind": "fixed", "sen": 300000 },
      "requiredDocuments": ["insuranceStatement"],
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "INSURANCE_EDU_MEDICAL", "name": "Education and medical insurance",
      "cap": { "kind": "fixed", "sen": 400000 },
      "requiredDocuments": ["insuranceStatement"],
      "notes": "YA2024 was RM 3,000.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "SOCSO_EIS", "name": "SOCSO and EIS contributions",
      "cap": { "kind": "fixed", "sen": 35000 },
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "EV_CHARGING",
      "name": "EV charging facilities and domestic food-waste composting machines",
      "cap": { "kind": "fixed", "sen": 250000 },
      "requiredDocuments": ["officialReceipt"],
      "notes": "Installation, rental, purchase, hire-purchase or subscription. Not for business use. YA2025 adds composting machines.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "HOUSING_LOAN_INTEREST", "name": "Housing loan interest, first home",
      "cap": { "kind": "tiered", "on": "propertyPrice", "tiers": [
        { "maxSen": 50000000, "sen": 700000 },
        { "maxSen": 75000000, "sen": 500000 }
      ] },
      "requiredDocuments": ["bankStatement"],
      "eligibility": { "op": "yaRange", "from": 2025, "to": 2027 },
      "notes": "New in YA2025. Sale and purchase agreement dated 1 January 2025 to 31 December 2027.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" }
  ],
  "retiredCodes": []
}
```

- [ ] **Step 4: Remove the placeholder resource**

```bash
rm Sources/TaxKit/Resources/Rules/.keep.json
```

- [ ] **Step 5: Run the test and confirm it passes**

Run: `swift test --filter RulebookIntegrityTests`
Expected: PASS, 9 tests.

If `cumulativeBasesAreConsistent` fails, check the band boundary convention.
`lowerBound` is the income **already taxed by the lower bands**, not the first ringgit of
this band. LHDN publishes "the first 5,000, the next 15,000", so the RM 5,001–20,000 row
is `lowerSen: 500000, upperSen: 2000000` and its width is a clean RM 15,000. Encoding the
lower bound as RM 5,001 makes every band one sen too narrow and the cumulative bases drift.

- [ ] **Step 6: Commit**

```bash
git add Sources/TaxKit/Resources/Rules Tests/TaxKitTests/RulebookIntegrityTests.swift
git commit -m "feat: add the verified YA2025 rulebook"
```

---

### Task 9: YA2024 and YA2023, and the generated-code staleness guard

**Files:**
- Create: `Sources/TaxKit/Resources/Rules/ya-2024.json`
- Create: `Sources/TaxKit/Resources/Rules/ya-2023.json`
- Modify: `Sources/TaxKit/Rules/ReliefCode+Generated.swift` (regenerated)
- Modify: `Tests/TaxKitTests/RulebookIntegrityTests.swift` (extend `shippedYears`, add guards)

**Interfaces:**
- Consumes: everything from Task 8.
- Produces: three shipped rulesets and the full `ReliefCode.allGenerated` list that
  Tasks 10–17 rely on.

Both files are exact copies of `ya-2025.json` with the deltas listed below applied. The
deltas are complete: anything not listed carries forward unchanged. Every difference was
read from the same LHDN page on 2026-08-23.

**YA2024 — apply to a copy of `ya-2025.json`:**

| Change |
|---|
| `yearOfAssessment` → `2024` |
| `PARENTS_MEDICAL.name` → `"Parents — medical, dental, special needs, carer"` |
| `PARENTS_MEDICAL.eligibility` → `{ "op": "claimant", "in": ["parent"] }` (no grandparent) |
| `DISABLED_SELF.cap.sen` → `600000`; drop its `notes` |
| `DISABLED_SPOUSE.cap.sen` → `500000`; drop its `notes` |
| `CHILD_DISABLED.cap.sen` → `600000`; drop its `notes` |
| `MEDICAL_LEARNDIS.cap.sen` → `400000`; drop its `notes` |
| `MEDICAL_DENTAL.notes` → `"New in YA2024."` |
| `MEDICAL_CHECKUP.name` → `"Full check-up, COVID-19 test, mental health"`; drop its `notes` |
| `LIFESTYLE_SPORTS.eligibility` → `{ "op": "claimant", "in": ["self", "spouse", "child"] }`; `notes` → `"Sports Development Act 1997."` |
| `INSURANCE_EDU_MEDICAL.cap.sen` → `300000`; drop its `notes` |
| `EV_CHARGING.name` → `"EV charging facilities"`; `notes` → `"Installation, rental, purchase, hire-purchase or subscription. Not for business use."` |
| `SSPN.notes` → `"Deposits in 2024 minus withdrawals in 2024."` |
| **Remove `HOUSING_LOAN_INTEREST` entirely** — it does not exist before YA2025 |

**YA2023 — apply to a copy of `ya-2024.json`:**

| Change |
|---|
| `yearOfAssessment` → `2023` |
| `PARENTS_MEDICAL.name` → `"Parents — medical treatment, special needs, carer"` (no dental) |
| **Remove the `PARENTS_CHECKUP` child** — the RM 1,000 parents check-up sub-limit starts in YA2024 |
| **Remove the `MEDICAL_DENTAL` child** — the dental sub-limit starts in YA2024 |
| `SSPN.notes` → `"Deposits in 2023 minus withdrawals in 2023."` |

Everything else, including all rate bands, is identical across the three years.

- [ ] **Step 1: Extend the integrity test and add the staleness guard**

In `Tests/TaxKitTests/RulebookIntegrityTests.swift`, change the year list:

```swift
    static let shippedYears = [2023, 2024, 2025]
```

and append these tests to the suite:

```swift
    @Test("every code in every ruleset has a generated ReliefCode constant")
    func generatedCodesAreUpToDate() throws {
        var inJSON: Set<String> = []
        for year in Self.shippedYears {
            let rules = try Self.load(year)
            inJSON.formUnion(rules.allReliefs.map(\.code.rawValue))
            inJSON.formUnion(rules.retiredCodes.map(\.retired.rawValue))
        }
        let generated = Set(ReliefCode.allGenerated.map(\.rawValue))

        #expect(inJSON.subtracting(generated).isEmpty,
                "rulebook codes with no constant — run `swift package "
                + "--allow-writing-to-package-directory generate-relief-codes`: "
                + "\(inJSON.subtracting(generated).sorted())")
        #expect(generated.subtracting(inJSON).isEmpty,
                "constants with no rulebook code — codes are append-only, so this means a "
                + "code was deleted instead of retired: \(generated.subtracting(inJSON).sorted())")
    }

    @Test("a code that disappears between years is retired, never deleted")
    func disappearingCodesAreRetired() throws {
        let years = Self.shippedYears.sorted()
        for (earlier, later) in zip(years, years.dropFirst()) {
            let before = Set(try Self.load(earlier).allReliefs.map(\.code))
            let after = try Self.load(later)
            let afterCodes = Set(after.allReliefs.map(\.code))
            let retired = Set(after.retiredCodes.map(\.retired))

            let vanished = before.subtracting(afterCodes).subtracting(retired)
            #expect(vanished.isEmpty,
                    "YA\(later) drops \(vanished.map(\.rawValue).sorted()) without a "
                    + "retiredCodes entry — historical entries would stop resolving")
        }
    }

    @Test("YA2024 matches LHDN where it differs from YA2025")
    func ya2024Spot() throws {
        let rules = try Self.load(2024)
        #expect(rules.relief(for: ReliefCode("DISABLED_SELF"))?.cap == .fixed(Money(ringgit: 6000)))
        #expect(rules.relief(for: ReliefCode("DISABLED_SPOUSE"))?.cap == .fixed(Money(ringgit: 5000)))
        #expect(rules.relief(for: ReliefCode("CHILD_DISABLED"))?.cap == .fixed(Money(ringgit: 6000)))
        #expect(rules.relief(for: ReliefCode("MEDICAL_LEARNDIS"))?.cap == .fixed(Money(ringgit: 4000)))
        #expect(rules.relief(for: ReliefCode("INSURANCE_EDU_MEDICAL"))?.cap == .fixed(Money(ringgit: 3000)))
        #expect(rules.relief(for: ReliefCode("HOUSING_LOAN_INTEREST")) == nil)
        #expect(rules.relief(for: ReliefCode("MEDICAL_DENTAL")) != nil)
    }

    @Test("YA2023 matches LHDN where it differs from YA2024")
    func ya2023Spot() throws {
        let rules = try Self.load(2023)
        #expect(rules.relief(for: ReliefCode("MEDICAL_DENTAL")) == nil)
        #expect(rules.relief(for: ReliefCode("PARENTS_CHECKUP")) == nil)
        #expect(rules.relief(for: ReliefCode("PARENTS_MEDICAL"))?.cap == .fixed(Money(ringgit: 8000)))
        #expect(rules.relief(for: .lifestyle)?.cap == .fixed(Money(ringgit: 2500)))
    }

    @Test("caps that LHDN kept flat really are flat across all three years")
    func unchangedCapsAreStable() throws {
        let stable: [ReliefCode] = [
            ReliefCode("SELF_AND_DEPENDENTS"), ReliefCode("PARENTS_MEDICAL"),
            ReliefCode("DISABLED_EQUIPMENT"), ReliefCode("EDUCATION_SELF"),
            ReliefCode("MEDICAL_SERIOUS"), .lifestyle, ReliefCode("LIFESTYLE_SPORTS"),
            ReliefCode("BREASTFEEDING"), ReliefCode("CHILDCARE"), ReliefCode("SSPN"),
            ReliefCode("SPOUSE_ALIMONY"), ReliefCode("CHILD_UNDER_18"),
            ReliefCode("CHILD_PRE_TERTIARY"), ReliefCode("CHILD_TERTIARY"),
            ReliefCode("CHILD_DISABLED_TERTIARY"), ReliefCode("INSURANCE_LIFE_EPF"),
            ReliefCode("PRS_ANNUITY"), ReliefCode("SOCSO_EIS"), ReliefCode("EV_CHARGING")
        ]
        let sets = try Self.shippedYears.map { try Self.load($0) }
        for code in stable {
            let caps = sets.compactMap { $0.relief(for: code)?.cap }
            #expect(caps.count == sets.count, "\(code) is missing from a year")
            #expect(Set(caps).count == 1, "\(code) cap changed across years: \(caps)")
        }
    }

    @Test("rate bands are identical across YA2023, YA2024 and YA2025")
    func bandsAreIdenticalAcrossYears() throws {
        let tables = try Self.shippedYears.map { try Self.load($0).brackets }
        #expect(Set(tables).count == 1)
    }
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `swift test --filter RulebookIntegrityTests`
Expected: FAIL — `ya-2023.json is not in the bundle`.

- [ ] **Step 3: Create the two rulesets**

```bash
cp Sources/TaxKit/Resources/Rules/ya-2025.json Sources/TaxKit/Resources/Rules/ya-2024.json
```

Apply every YA2024 row from the table above to `ya-2024.json`, then:

```bash
cp Sources/TaxKit/Resources/Rules/ya-2024.json Sources/TaxKit/Resources/Rules/ya-2023.json
```

Apply every YA2023 row from the table above to `ya-2023.json`.

Confirm all three parse before running the suite:

```bash
for f in Sources/TaxKit/Resources/Rules/ya-*.json; do
  python3 -c "import json,sys; json.load(open('$f')); print('$f ok')"
done
```

- [ ] **Step 4: Regenerate the relief codes**

```bash
swift package --allow-writing-to-package-directory generate-relief-codes
```

Expected: `Wrote 32 relief codes to .../ReliefCode+Generated.swift`

Review the diff. It should add every code from the rulebook and keep `lifestyle` and
`medicalSerious` from the hand-seeded version. If the count is not 32, a code is missing
from a ruleset or duplicated.

- [ ] **Step 5: Run the full suite and confirm it passes**

Run: `swift test`
Expected: PASS. `RulebookIntegrityTests` now runs its year-parameterised tests three times
each plus six new tests.

If `generatedCodesAreUpToDate` reports constants with no rulebook code, a code was deleted
from a JSON file rather than moved into `retiredCodes`. Restore it, or add the retirement.

- [ ] **Step 6: Commit**

```bash
git add Sources/TaxKit/Resources/Rules Sources/TaxKit/Rules/ReliefCode+Generated.swift Tests/TaxKitTests/RulebookIntegrityTests.swift
git commit -m "feat: add verified YA2023 and YA2024 rulebooks"
```

---

### Task 10: Bracket maths

**Files:**
- Create: `Sources/TaxKit/Engine/TaxCalculator.swift`
- Test: `Tests/TaxKitTests/BracketTableTests.swift`

**Interfaces:**
- Consumes: `Money` (Task 1), `BracketTable`, `Band` (Task 6).
- Produces:
  - `BracketTable.band(for chargeable: Money) -> Band?`
  - `BracketTable.tax(on chargeable: Money) -> Money`
  - `BracketTable.marginalRate(at chargeable: Money) -> Decimal`
  - `BracketTable.taxSaved(reducing chargeable: Money, by relief: Money) -> Money`

`taxSaved` is a difference of two `tax(on:)` calls, not `relief × marginalRate`. When a
relief straddles a band boundary the single-rate shortcut over-states the saving, and this
number is the app's headline claim — it has to be right.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxKitTests/BracketTableTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("Bracket maths") struct BracketTableTests {

    static func table() throws -> BracketTable {
        try RulebookIntegrityTests.load(2025).brackets
    }

    @Test("tax is zero up to the end of the first band")
    func zeroBand() throws {
        let t = try Self.table()
        #expect(t.tax(on: .zero) == .zero)
        #expect(t.tax(on: Money(ringgit: 5000)) == .zero)
    }

    @Test("tax matches LHDN's published cumulative figures at every band boundary")
    func boundariesMatchPublishedTable() throws {
        let t = try Self.table()
        let published: [(ringgit: Int, tax: Int)] = [
            (5_000, 0), (20_000, 150), (35_000, 600), (50_000, 1_500),
            (70_000, 3_700), (100_000, 9_400), (400_000, 84_400),
            (600_000, 136_400), (2_000_000, 528_400)
        ]
        for row in published {
            #expect(t.tax(on: Money(ringgit: Decimal(row.ringgit)))
                    == Money(ringgit: Decimal(row.tax)),
                    "chargeable RM \(row.ringgit)")
        }
    }

    @Test("tax one ringgit either side of a boundary moves by the right rate")
    func nearBoundaries() throws {
        let t = try Self.table()
        // RM 70,001 is the first ringgit taxed at 19%.
        #expect(t.tax(on: Money(ringgit: 70_001)) == Money(ringgit: Decimal(string: "3700.19")!))
        // RM 69,999 is still in the 11% band: 1,500 + 19,999 x 0.11 = 3,699.89
        #expect(t.tax(on: Money(ringgit: 69_999)) == Money(ringgit: Decimal(string: "3699.89")!))
    }

    @Test("the worked example from the spec")
    func specExample() throws {
        let t = try Self.table()
        // Chargeable RM 92,400: 3,700 + (92,400 - 70,000) x 0.19 = 3,700 + 4,256 = 7,956
        #expect(t.tax(on: Money(ringgit: 92_400)) == Money(ringgit: 7_956))
        #expect(t.marginalRate(at: Money(ringgit: 92_400)) == Decimal(string: "0.19")!)
    }

    @Test("the top band is open-ended")
    func topBand() throws {
        let t = try Self.table()
        // 528,400 + 1,000,000 x 0.30 = 828,400
        #expect(t.tax(on: Money(ringgit: 3_000_000)) == Money(ringgit: 828_400))
        #expect(t.marginalRate(at: Money(ringgit: 9_999_999)) == Decimal(string: "0.30")!)
    }

    @Test("tax saved is the real difference, not relief times the marginal rate")
    func taxSavedStraddlingABoundary() throws {
        let t = try Self.table()
        // Chargeable 71,000 reduced by 3,000 lands at 68,000, crossing the 19%/11% edge.
        let chargeable = Money(ringgit: 71_000)
        let relief = Money(ringgit: 3_000)
        let saved = t.taxSaved(reducing: chargeable, by: relief)

        #expect(saved == t.tax(on: chargeable) - t.tax(on: Money(ringgit: 68_000)))
        // The single-rate shortcut would say 3,000 x 0.19 = 570. The truth is less.
        #expect(saved < relief.applying(Decimal(string: "0.19")!))
        // 3,890 - 3,480 = 410
        #expect(saved == Money(ringgit: 410))
    }

    @Test("tax saved within one band equals relief times that band's rate")
    func taxSavedWithinOneBand() throws {
        let t = try Self.table()
        let saved = t.taxSaved(reducing: Money(ringgit: 92_400), by: Money(ringgit: 800))
        #expect(saved == Money(ringgit: 152))
    }

    @Test("relief larger than chargeable income cannot save more than the tax owed")
    func reliefExceedsIncome() throws {
        let t = try Self.table()
        let chargeable = Money(ringgit: 30_000)
        #expect(t.taxSaved(reducing: chargeable, by: Money(ringgit: 90_000))
                == t.tax(on: chargeable))
    }

    @Test("negative chargeable income is treated as zero")
    func negativeIncome() throws {
        let t = try Self.table()
        #expect(t.tax(on: Money(sen: -5_000)) == .zero)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter BracketTableTests`
Expected: FAIL — `value of type 'BracketTable' has no member 'tax'`.

- [ ] **Step 3: Implement the calculator**

Create `Sources/TaxKit/Engine/TaxCalculator.swift`:

```swift
import Foundation

extension BracketTable {

    /// The band containing `chargeable`. Income at exactly a band's `upperBound` belongs
    /// to that band, matching LHDN's "5,001 – 20,000" presentation.
    public func band(for chargeable: Money) -> Band? {
        let clamped = max(chargeable, .zero)
        return bands.last { band in
            clamped >= band.lowerBound
                && (band.upperBound.map { clamped <= $0 } ?? true)
        }
    }

    /// Total income tax owed on `chargeable`, before rebates.
    ///
    /// Table-driven: the cumulative base for each band is taken verbatim from LHDN's
    /// published figures, so there is no loop accumulating rounding error.
    public func tax(on chargeable: Money) -> Money {
        let clamped = max(chargeable, .zero)
        guard let band = band(for: clamped) else { return .zero }
        return band.cumulativeBase + (clamped - band.lowerBound).applying(band.rate)
    }

    /// The rate on the next ringgit of income.
    public func marginalRate(at chargeable: Money) -> Decimal {
        band(for: max(chargeable, .zero))?.rate ?? 0
    }

    /// The tax a relief actually saves.
    ///
    /// Computed as a difference of two `tax(on:)` calls rather than
    /// `relief.applying(marginalRate)`, because a relief that straddles a band boundary
    /// saves less than the higher rate implies. This figure is the headline number on the
    /// home screen, so the shortcut is not acceptable.
    public func taxSaved(reducing chargeable: Money, by relief: Money) -> Money {
        let before = max(chargeable, .zero)
        let after = max(before - relief, .zero)
        return tax(on: before) - tax(on: after)
    }
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `swift test --filter BracketTableTests`
Expected: PASS, 9 tests.

If `boundariesMatchPublishedTable` fails at RM 20,000, `band(for:)` is picking the wrong
band at a shared boundary. `bands.last` is deliberate: RM 20,000 satisfies both the
`5,001–20,000` band and the start of the next, and LHDN taxes it in the lower one — but
the two agree numerically there, so either choice gives the same tax. The `last` form is
what makes the open-ended top band resolve.

- [ ] **Step 5: Commit**

```bash
git add Sources/TaxKit/Engine/TaxCalculator.swift Tests/TaxKitTests/BracketTableTests.swift
git commit -m "feat: add table-driven bracket maths and true tax-saved"
```

---

### Task 11: Evaluator inputs, outputs, and flat-cap evaluation

**Files:**
- Create: `Sources/TaxKit/Engine/Snapshots.swift`
- Create: `Sources/TaxKit/Engine/ReliefAssessment.swift`
- Create: `Sources/TaxKit/Engine/Evaluator.swift`
- Test: `Tests/TaxKitTests/EvaluatorCapTests.swift`

**Interfaces:**
- Consumes: `Money`, `ReliefCode`, `RuleSet`, `Cap`, `DocumentKind`, `Facts` types.
- Produces:
  - `DependentSnapshot`, `TaxYearSnapshot`, `EntrySnapshot`.
  - `Eligibility`, `RequirementCheck`, `ReliefAssessment`, `UnresolvedEntry`,
    `EvaluationResult`.
  - `func evaluate(ruleSet: RuleSet, year: TaxYearSnapshot, entries: [EntrySnapshot]) -> EvaluationResult`

**Deviation from spec §7:** the spec gives `evaluate` a return type of `[ReliefAssessment]`.
This plan returns `EvaluationResult`, which also carries `unresolved` entries, the totals,
and the chargeable-income figure. Spec §7 separately requires that a code with no rule
"renders as a visible amber row, never a silent drop" — a bare array has nowhere to put
those, so the richer return type is what actually satisfies the requirement.

This task implements `.fixed` caps only. Tasks 12 and 13 add the other cap kinds; Task 14
adds eligibility and requirements; Task 15 adds `taxSaved`. Until then those fields are
present with neutral values (`.eligible`, `[]`, `nil`) so the type is stable for callers.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxKitTests/EvaluatorCapTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

/// Shared builders for the evaluator suites.
enum Fixture {
    static func year(_ ya: Int = 2025,
                     gross: Money? = nil,
                     dependents: [DependentSnapshot] = []) -> TaxYearSnapshot {
        var snapshot = TaxYearSnapshot(year: ya)
        snapshot.grossIncome = gross
        snapshot.dependents = dependents
        return snapshot
    }

    static func entry(_ code: ReliefCode,
                      _ ringgit: Decimal,
                      claimant: Claimant = .individual,
                      dependentID: UUID? = nil,
                      documents: Set<DocumentKind> = [.officialReceipt]) -> EntrySnapshot {
        EntrySnapshot(id: UUID(),
                      code: code,
                      amount: Money(ringgit: ringgit),
                      claimant: claimant,
                      dependentID: dependentID,
                      documentKinds: documents)
    }

    static func rules(_ ya: Int = 2025) throws -> RuleSet {
        try RulebookIntegrityTests.load(ya)
    }
}

@Suite("Evaluator — flat caps") struct EvaluatorCapTests {

    @Test("an unused relief reports its full cap as headroom")
    func unusedRelief() throws {
        let result = evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
        let lifestyle = try #require(result.assessment(for: .lifestyle))
        #expect(lifestyle.cap == Money(ringgit: 2500))
        #expect(lifestyle.claimed == .zero)
        #expect(lifestyle.allowed == .zero)
        #expect(lifestyle.headroom == Money(ringgit: 2500))
    }

    @Test("claims accumulate and reduce headroom")
    func claimsAccumulate() throws {
        let result = evaluate(
            ruleSet: try Fixture.rules(),
            year: Fixture.year(),
            entries: [Fixture.entry(.lifestyle, 1200), Fixture.entry(.lifestyle, 500)])
        let lifestyle = try #require(result.assessment(for: .lifestyle))
        #expect(lifestyle.claimed == Money(ringgit: 1700))
        #expect(lifestyle.allowed == Money(ringgit: 1700))
        #expect(lifestyle.headroom == Money(ringgit: 800))
    }

    @Test("over-claiming is capped and headroom never goes negative")
    func overClaiming() throws {
        let result = evaluate(
            ruleSet: try Fixture.rules(),
            year: Fixture.year(),
            entries: [Fixture.entry(.lifestyle, 4000)])
        let lifestyle = try #require(result.assessment(for: .lifestyle))
        #expect(lifestyle.claimed == Money(ringgit: 4000))   // what the user entered
        #expect(lifestyle.allowed == Money(ringgit: 2500))   // what LHDN will allow
        #expect(lifestyle.headroom == .zero)
    }

    @Test("every relief in the ruleset appears in the result, claimed or not")
    func everyReliefAppears() throws {
        let rules = try Fixture.rules()
        let result = evaluate(ruleSet: rules, year: Fixture.year(), entries: [])
        let assessed = Set(result.allAssessments.map(\.code))
        #expect(assessed == Set(rules.allReliefs.map(\.code)))
    }

    @Test("assessments carry the rule's provenance through to the UI")
    func provenance() throws {
        let lifestyle = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
                .assessment(for: .lifestyle))
        #expect(lifestyle.name.contains("Lifestyle"))
        #expect(lifestyle.sourceURL.host()?.hasSuffix("hasil.gov.my") == true)
        #expect(lifestyle.unverified == false)
    }

    @Test("a code absent from this year surfaces as unresolved, never silently dropped")
    func unknownCodeSurfaces() throws {
        // HOUSING_LOAN_INTEREST does not exist in YA2024.
        let entry = Fixture.entry(ReliefCode("HOUSING_LOAN_INTEREST"), 3000)
        let result = evaluate(ruleSet: try Fixture.rules(2024),
                              year: Fixture.year(2024), entries: [entry])
        #expect(result.unresolved.count == 1)
        #expect(result.unresolved[0].entryID == entry.id)
        #expect(result.unresolved[0].reason == .unknownInThisYear)
    }

    @Test("a retired code resolves to its successor rather than vanishing")
    func retiredCodeSurfacesSuccessor() throws {
        var rules = try Fixture.rules()
        rules = try Self.withRetirement(rules, retired: "BOOKS", supersededBy: "LIFESTYLE")
        let entry = Fixture.entry(ReliefCode("BOOKS"), 120)
        let result = evaluate(ruleSet: rules, year: Fixture.year(), entries: [entry])
        #expect(result.unresolved.count == 1)
        #expect(result.unresolved[0].reason == .retired(supersededBy: .lifestyle))
        // The amount is NOT counted against Lifestyle — the user must confirm the move.
        #expect(result.assessment(for: .lifestyle)?.claimed == .zero)
    }

    /// Re-encodes a ruleset with an extra retirement, so the test does not depend on a
    /// retirement existing in the shipped rulebook.
    static func withRetirement(_ rules: RuleSet,
                               retired: String,
                               supersededBy: String) throws -> RuleSet {
        var object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(rules)) as! [String: Any]
        object["retiredCodes"] = [["retired": retired,
                                   "supersededBy": supersededBy,
                                   "fromYA": 2021]]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(RuleSet.self, from: data)
    }

    @Test("totals count the allowed amounts, not the claimed ones")
    func totals() throws {
        let rules = try Fixture.rules()
        // Measured as a delta against the no-entry baseline, so the automatic reliefs
        // (which are granted with no entry) do not make this assertion brittle.
        let baseline = evaluate(ruleSet: rules, year: Fixture.year(), entries: [])
        let withEntries = evaluate(
            ruleSet: rules, year: Fixture.year(),
            entries: [Fixture.entry(.lifestyle, 4000), Fixture.entry(ReliefCode("SSPN"), 1000)])
        // Lifestyle is capped at 2,500 despite the 4,000 claim, plus 1,000 of SSPN.
        #expect(withEntries.totalAllowed - baseline.totalAllowed == Money(ringgit: 3500))
    }

    @Test("an automatic relief is granted without any entry")
    func automaticGrant() throws {
        let individual = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
                .assessment(for: ReliefCode("SELF_AND_DEPENDENTS")))
        #expect(individual.allowed == Money(ringgit: 9000))
        #expect(individual.headroom == .zero)
    }
}
```

`RuleSet` and `ReliefRule` declare only `init(from:)`, so Swift still synthesises their
`encode(to:)` — and the synthesised code can see their `private` CodingKeys because it is
generated inside the type. No access-level change is needed.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter EvaluatorCapTests`
Expected: FAIL — `cannot find 'TaxYearSnapshot' in scope`.

- [ ] **Step 3: Implement the snapshots**

Create `Sources/TaxKit/Engine/Snapshots.swift`:

```swift
import Foundation

/// A dependent as the engine sees them. Ages are resolved at year end by the caller,
/// so the engine never touches a calendar.
public struct DependentSnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var ageAtYearEnd: Int?
    public var educationLevel: EducationLevel?
    public var isDisabled: Bool?
    /// 100 when claimed in full, 50 when split with a spouse.
    public var claimPercentage: Int

    public init(id: UUID = UUID(),
                name: String = "",
                ageAtYearEnd: Int? = nil,
                educationLevel: EducationLevel? = nil,
                isDisabled: Bool? = nil,
                claimPercentage: Int = 100) {
        self.id = id
        self.name = name
        self.ageAtYearEnd = ageAtYearEnd
        self.educationLevel = educationLevel
        self.isDisabled = isDisabled
        self.claimPercentage = claimPercentage
    }

    var facts: DependentFacts {
        DependentFacts(ageAtYearEnd: ageAtYearEnd,
                       educationLevel: educationLevel,
                       isDisabled: isDisabled)
    }
}

/// One Year of Assessment's household and income facts. Every optional means
/// "not yet known", which produces `.needsInfo` rather than a silent ineligibility.
public struct TaxYearSnapshot: Hashable, Sendable {
    public var year: Int
    /// Aggregate income before any relief. `nil` disables all tax-saved maths.
    public var grossIncome: Money?
    public var maritalStatus: MaritalStatus?
    public var spouseHasIncome: Bool?
    public var assessmentType: AssessmentType?
    public var employmentType: EmploymentType?
    public var gender: Gender?
    public var dependents: [DependentSnapshot]
    /// Purchase price of the first home, for tiered housing loan interest relief.
    public var propertyPriceSen: Int?
    /// JKM-registered disability status, gating the two disabled-person reliefs.
    public var selfIsDisabled: Bool?
    public var spouseIsDisabled: Bool?
    /// The most recent YA in which a once-every-N-years relief was claimed.
    public var lastClaimedYear: [ReliefCode: Int]

    public init(year: Int,
                grossIncome: Money? = nil,
                maritalStatus: MaritalStatus? = nil,
                spouseHasIncome: Bool? = nil,
                assessmentType: AssessmentType? = nil,
                employmentType: EmploymentType? = nil,
                gender: Gender? = nil,
                dependents: [DependentSnapshot] = [],
                propertyPriceSen: Int? = nil,
                selfIsDisabled: Bool? = nil,
                spouseIsDisabled: Bool? = nil,
                lastClaimedYear: [ReliefCode: Int] = [:]) {
        self.year = year
        self.grossIncome = grossIncome
        self.maritalStatus = maritalStatus
        self.spouseHasIncome = spouseHasIncome
        self.assessmentType = assessmentType
        self.employmentType = employmentType
        self.gender = gender
        self.dependents = dependents
        self.propertyPriceSen = propertyPriceSen
        self.selfIsDisabled = selfIsDisabled
        self.spouseIsDisabled = spouseIsDisabled
        self.lastClaimedYear = lastClaimedYear
    }
}

/// One logged claim line.
public struct EntrySnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var code: ReliefCode
    public var amount: Money
    public var claimant: Claimant
    public var dependentID: UUID?
    /// The kinds of document attached, for requirement checking.
    public var documentKinds: Set<DocumentKind>

    public init(id: UUID = UUID(),
                code: ReliefCode,
                amount: Money,
                claimant: Claimant = .individual,
                dependentID: UUID? = nil,
                documentKinds: Set<DocumentKind> = []) {
        self.id = id
        self.code = code
        self.amount = amount
        self.claimant = claimant
        self.dependentID = dependentID
        self.documentKinds = documentKinds
    }
}
```

- [ ] **Step 4: Implement the result types**

Create `Sources/TaxKit/Engine/ReliefAssessment.swift`:

```swift
import Foundation

/// Three-valued, mirroring `PredicateOutcome`. `needsInfo` is the case that earns its
/// keep: treating an unanswered question as ineligibility silently costs the user money.
public enum Eligibility: Hashable, Sendable {
    case eligible
    case ineligible(reasons: [String])
    case needsInfo(questions: [ProfileQuestion])

    public var isEligible: Bool { self == .eligible }
}

/// Whether a claim carries the documents LHDN asks for.
public struct RequirementCheck: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case satisfied
        /// The entries that are missing this document kind.
        case missing(entryIDs: [UUID])
    }

    public var kind: DocumentKind
    public var status: Status

    public var isSatisfied: Bool { status == .satisfied }
}

/// What the user can claim under one relief, and what it is worth.
public struct ReliefAssessment: Hashable, Sendable, Identifiable {
    public var code: ReliefCode
    public var name: String
    /// The effective ceiling for this user, after tier selection and per-dependent
    /// multiplication.
    public var cap: Money
    /// What the user actually entered.
    public var claimed: Money
    /// What LHDN would allow — `claimed` capped, and further limited by any parent.
    public var allowed: Money
    /// `cap - allowed`, never negative.
    public var headroom: Money
    public var eligibility: Eligibility
    public var requirements: [RequirementCheck]
    /// Tax saved if the headroom were fully used. `nil` when income is unknown or the
    /// figure is unverified.
    public var taxSaved: Money?
    public var unverified: Bool
    public var sourceURL: URL
    public var notes: String?
    public var children: [ReliefAssessment]

    public var id: ReliefCode { code }

    /// This assessment and every descendant, depth-first.
    public var selfAndDescendants: [ReliefAssessment] {
        [self] + children.flatMap(\.selfAndDescendants)
    }
}

/// An entry whose code no rule in this year matches. Surfaced so the UI can show an
/// actionable amber row instead of dropping the claim.
public struct UnresolvedEntry: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        case retired(supersededBy: ReliefCode?)
        case unknownInThisYear
    }

    public var entryID: UUID
    public var code: ReliefCode
    public var amount: Money
    public var reason: Reason
}

public struct EvaluationResult: Hashable, Sendable {
    public var yearOfAssessment: Int
    /// Top-level reliefs; sub-limits hang off their parents' `children`.
    public var assessments: [ReliefAssessment]
    public var unresolved: [UnresolvedEntry]
    /// Income after every allowed relief. `nil` when income is unknown.
    public var chargeableIncome: Money?
    /// Estimated tax on `chargeableIncome`. `nil` when income is unknown.
    public var estimatedTax: Money?

    /// Every assessment including nested sub-limits, depth-first.
    public var allAssessments: [ReliefAssessment] {
        assessments.flatMap(\.selfAndDescendants)
    }

    public func assessment(for code: ReliefCode) -> ReliefAssessment? {
        allAssessments.first { $0.code == code }
    }

    /// Total relief LHDN would allow. Counts top-level reliefs only, because a
    /// sub-limit's amount is already inside its parent's `allowed`.
    public var totalAllowed: Money {
        assessments.reduce(Money.zero) { $0 + $1.allowed }
    }
}
```

- [ ] **Step 5: Implement the evaluator**

Create `Sources/TaxKit/Engine/Evaluator.swift`:

```swift
import Foundation

/// Turns a rulebook plus a user's year into per-relief assessments.
///
/// Pure: no I/O, no dates, no randomness, no SwiftData. The same inputs always produce
/// the same output, which is what makes the golden-file tests in Task 17 meaningful.
public func evaluate(ruleSet: RuleSet,
                     year: TaxYearSnapshot,
                     entries: [EntrySnapshot]) -> EvaluationResult {

    let known = Set(ruleSet.allReliefs.map(\.code))
    let retirements = Dictionary(
        ruleSet.retiredCodes.map { ($0.retired, $0.supersededBy) },
        uniquingKeysWith: { first, _ in first })

    // Entries whose code this year does not recognise never disappear; they are reported.
    var unresolved: [UnresolvedEntry] = []
    var usable: [EntrySnapshot] = []
    for entry in entries {
        if known.contains(entry.code) {
            usable.append(entry)
        } else if let successor = retirements[entry.code] {
            unresolved.append(UnresolvedEntry(entryID: entry.id, code: entry.code,
                                              amount: entry.amount,
                                              reason: .retired(supersededBy: successor)))
        } else {
            unresolved.append(UnresolvedEntry(entryID: entry.id, code: entry.code,
                                              amount: entry.amount,
                                              reason: .unknownInThisYear))
        }
    }

    let byCode = Dictionary(grouping: usable, by: \.code)
    let assessments = ruleSet.reliefs.map {
        assess(rule: $0, year: year, entriesByCode: byCode)
    }

    var result = EvaluationResult(yearOfAssessment: ruleSet.yearOfAssessment,
                                  assessments: assessments,
                                  unresolved: unresolved,
                                  chargeableIncome: nil,
                                  estimatedTax: nil)

    if let gross = year.grossIncome {
        let chargeable = max(gross - result.totalAllowed, .zero)
        result.chargeableIncome = chargeable
        result.estimatedTax = ruleSet.brackets.tax(on: chargeable)
    }
    return result
}

/// Assesses one rule and its sub-limits.
///
/// Cap kinds beyond `.fixed` arrive in Tasks 12 and 13; eligibility and requirements in
/// Task 14; `taxSaved` in Task 15.
private func assess(rule: ReliefRule,
                    year: TaxYearSnapshot,
                    entriesByCode: [ReliefCode: [EntrySnapshot]]) -> ReliefAssessment {

    let children = rule.children.map {
        assess(rule: $0, year: year, entriesByCode: entriesByCode)
    }

    let ownEntries = entriesByCode[rule.code] ?? []
    let ownClaimed = ownEntries.reduce(Money.zero) { $0 + $1.amount }
    let entered = children.reduce(ownClaimed) { $0 + $1.claimed }

    let cap = effectiveCap(rule.cap, year: year)
    let eligibility = Eligibility.eligible      // Task 13 computes this properly

    // An automatic relief is granted in full once it is eligible — LHDN gives the
    // RM 9,000 individual relief to every resident, and child and spouse reliefs follow
    // from the household, not from a receipt.
    let granted = rule.automatic && eligibility.isEligible
    let claimed = granted ? cap : entered
    let allowed = granted ? cap : entered.clamped(to: cap)
    let headroom = max(cap - allowed, .zero)

    return ReliefAssessment(code: rule.code,
                            name: rule.name,
                            cap: cap,
                            claimed: claimed,
                            allowed: allowed,
                            headroom: headroom,
                            eligibility: eligibility,
                            requirements: [],
                            taxSaved: nil,
                            unverified: rule.unverified,
                            sourceURL: rule.sourceURL,
                            notes: rule.notes,
                            children: children)
}

/// Resolves a declared cap into a concrete ceiling for this user.
/// Extended in Tasks 12 and 13.
private func effectiveCap(_ cap: Cap, year: TaxYearSnapshot) -> Money {
    switch cap {
    case .fixed(let amount):
        return amount
    case .perDependent(let amount):
        return amount
    case .tiered(_, let tiers):
        return tiers.map(\.amount).max() ?? .zero
    }
}
```

- [ ] **Step 6: Run the test and confirm it passes**

Run: `swift test --filter EvaluatorCapTests`
Expected: PASS, 8 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/TaxKit/Engine Sources/TaxKit/Rules Tests/TaxKitTests/EvaluatorCapTests.swift
git commit -m "feat: add evaluator with flat-cap assessment and unresolved-entry reporting"
```

---

### Task 12: Per-dependent and tiered caps

**Files:**
- Modify: `Sources/TaxKit/Engine/Evaluator.swift` (`effectiveCap`)
- Test: `Tests/TaxKitTests/EvaluatorCapKindTests.swift`

**Interfaces:**
- Consumes: everything from Task 11.
- Produces: `effectiveCap` now resolves `.perDependent` and `.tiered`, and returns the
  questions a cap cannot be resolved without. Signature becomes
  `effectiveCap(_ cap: Cap, rule: ReliefRule, year: TaxYearSnapshot) -> (cap: Money, missing: [ProfileQuestion])`.

Two rules:

- **`.perDependent`** multiplies by the dependents this rule's own eligibility predicate
  accepts, each scaled by that dependent's `claimPercentage`. Three children under 18 at
  100% give RM 6,000; two at 100% and one at 50% give RM 5,000.
- **`.tiered`** picks the first tier whose `maxSen` covers the fact. When the fact is
  unknown the cap is the **largest** tier and the missing question is reported, so the UI
  shows the full opportunity with a prompt rather than hiding it behind a zero.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxKitTests/EvaluatorCapKindTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("Evaluator — cap kinds") struct EvaluatorCapKindTests {

    static func child(age: Int, percent: Int = 100,
                      education: EducationLevel? = nil,
                      disabled: Bool = false) -> DependentSnapshot {
        DependentSnapshot(name: "Child \(age)", ageAtYearEnd: age,
                          educationLevel: education, isDisabled: disabled,
                          claimPercentage: percent)
    }

    @Test("per-dependent cap multiplies by the number of qualifying dependents")
    func perDependentMultiplies() throws {
        let year = Fixture.year(dependents: [child(age: 5), child(age: 10), child(age: 16)])
        let result = evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
        #expect(result.assessment(for: ReliefCode("CHILD_UNDER_18"))?.cap
                == Money(ringgit: 6000))
    }

    @Test("a 50% split halves that dependent's share only")
    func splitClaim() throws {
        let year = Fixture.year(dependents: [child(age: 5), child(age: 10, percent: 50)])
        let result = evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
        #expect(result.assessment(for: ReliefCode("CHILD_UNDER_18"))?.cap
                == Money(ringgit: 3000))
    }

    @Test("dependents who fail the rule's own predicate do not count")
    func nonQualifyingDependentsExcluded() throws {
        // An 18-year-old is not "under 18"; a tertiary student is not pre-tertiary.
        let year = Fixture.year(dependents: [
            child(age: 5),
            child(age: 18, education: .tertiaryLocal)
        ])
        let result = evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
        #expect(result.assessment(for: ReliefCode("CHILD_UNDER_18"))?.cap
                == Money(ringgit: 2000))
        #expect(result.assessment(for: ReliefCode("CHILD_TERTIARY"))?.cap
                == Money(ringgit: 8000))
        #expect(result.assessment(for: ReliefCode("CHILD_PRE_TERTIARY"))?.cap == .zero)
    }

    @Test("no dependents means a zero cap, not the per-child amount")
    func noDependents() throws {
        let result = evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
        #expect(result.assessment(for: ReliefCode("CHILD_UNDER_18"))?.cap == .zero)
    }

    @Test("tiered cap selects the tier the property price falls in")
    func tieredSelection() throws {
        var cheap = Fixture.year()
        cheap.propertyPriceSen = Money(ringgit: 450_000).sen
        #expect(evaluate(ruleSet: try Fixture.rules(), year: cheap, entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST"))?.cap
                == Money(ringgit: 7000))

        var mid = Fixture.year()
        mid.propertyPriceSen = Money(ringgit: 600_000).sen
        #expect(evaluate(ruleSet: try Fixture.rules(), year: mid, entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST"))?.cap
                == Money(ringgit: 5000))
    }

    @Test("a price above every tier gives no relief")
    func aboveEveryTier() throws {
        var expensive = Fixture.year()
        expensive.propertyPriceSen = Money(ringgit: 900_000).sen
        #expect(evaluate(ruleSet: try Fixture.rules(), year: expensive, entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST"))?.cap == .zero)
    }

    @Test("an unknown tier fact shows the best case and asks the question")
    func unknownTierFact() throws {
        let assessment = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST")))
        #expect(assessment.cap == Money(ringgit: 7000))
        #expect(assessment.eligibility == .needsInfo(questions: [.propertyPrice]))
    }

    @Test("a boundary price lands in the lower tier")
    func tierBoundary() throws {
        var exact = Fixture.year()
        exact.propertyPriceSen = Money(ringgit: 500_000).sen
        #expect(evaluate(ruleSet: try Fixture.rules(), year: exact, entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST"))?.cap
                == Money(ringgit: 7000))
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter EvaluatorCapKindTests`
Expected: FAIL — `perDependentMultiplies` reports RM 2,000 instead of RM 6,000, because
Task 11's `effectiveCap` returns the per-child amount unmultiplied.

- [ ] **Step 3: Replace `effectiveCap` in `Evaluator.swift`**

```swift
/// Resolves a declared cap into a concrete ceiling for this user, along with any
/// question that had to go unanswered to get there.
private func effectiveCap(_ cap: Cap,
                          rule: ReliefRule,
                          year: TaxYearSnapshot) -> (cap: Money, missing: [ProfileQuestion]) {
    switch cap {
    case .fixed(let amount):
        return (amount, [])

    case .perDependent(let perChild):
        // Each dependent is tested against this rule's own predicate, so
        // CHILD_TERTIARY counts only tertiary students and CHILD_UNDER_18 only under-18s.
        var total = Money.zero
        var missing: [ProfileQuestion] = []
        for dependent in year.dependents {
            var facts = year.facts(claimant: .child)
            facts.dependent = dependent.facts
            switch rule.eligibility?.evaluate(facts) ?? .satisfied {
            case .satisfied:
                total = total + perChild.applying(Decimal(dependent.claimPercentage) / 100)
            case .failed:
                continue
            case .unknown(let questions):
                missing.append(contentsOf: questions)
            }
        }
        return (total, missing.deduplicated())

    case .tiered(let fact, let tiers):
        let ordered = tiers.sorted { ($0.maxSen ?? .max) < ($1.maxSen ?? .max) }
        guard let value = year.value(of: fact) else {
            // Show the best case and ask, rather than hiding the relief behind a zero.
            return (ordered.map(\.amount).max() ?? .zero, [fact.question])
        }
        let selected = ordered.first { tier in tier.maxSen.map { value <= $0 } ?? true }
        return (selected?.amount ?? .zero, [])
    }
}

extension TieredFact {
    var question: ProfileQuestion {
        switch self {
        case .propertyPrice: .propertyPrice
        }
    }
}

extension TaxYearSnapshot {
    func value(of fact: TieredFact) -> Int? {
        switch fact {
        case .propertyPrice: propertyPriceSen
        }
    }

    /// The household facts, for a claim made in respect of `claimant`.
    func facts(claimant: Claimant?) -> Facts {
        Facts(yearOfAssessment: year,
              maritalStatus: maritalStatus,
              spouseHasIncome: spouseHasIncome,
              assessmentType: assessmentType,
              employmentType: employmentType,
              gender: gender,
              claimant: claimant,
              selfIsDisabled: selfIsDisabled,
              spouseIsDisabled: spouseIsDisabled)
    }
}
```

- [ ] **Step 4: Thread the missing questions through `assess`**

In `assess`, replace the cap line and the `eligibility` argument:

```swift
    let resolved = effectiveCap(rule.cap, rule: rule, year: year)
    let cap = resolved.cap
    let allowed = claimed.clamped(to: cap)
    let headroom = max(cap - allowed, .zero)
    let eligibility: Eligibility = resolved.missing.isEmpty
        ? .eligible
        : .needsInfo(questions: resolved.missing)
```

and pass `eligibility: eligibility` instead of `eligibility: .eligible`. Task 13 replaces
this with the full three-state computation; the cap's missing questions merge into it.

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `swift test --filter EvaluatorCapKindTests`
Expected: PASS, 8 tests.

`nonQualifyingDependentsExcluded` is the one to watch. If `CHILD_PRE_TERTIARY` comes back
non-zero, the per-dependent branch is not applying the rule's predicate — check that
`facts.dependent` is set before evaluating.

- [ ] **Step 6: Commit**

```bash
git add Sources/TaxKit/Engine/Evaluator.swift Tests/TaxKitTests/EvaluatorCapKindTests.swift
git commit -m "feat: resolve per-dependent and tiered caps"
```

---

### Task 13: Eligibility and documentary requirements

**Files:**
- Modify: `Sources/TaxKit/Engine/Evaluator.swift` (`assess`)
- Test: `Tests/TaxKitTests/EvaluatorEligibilityTests.swift`

**Interfaces:**
- Consumes: Task 12's `effectiveCap`, `EligibilityPredicate.evaluate`.
- Produces: `ReliefAssessment.eligibility` fully computed, and
  `ReliefAssessment.requirements` populated by set-difference.

Requirement checking is the whole of spec feature 3: for each `DocumentKind` the rule
requires, an entry satisfies it if that kind is among its attached documents. A relief with
no entries has no requirement failures — there is nothing yet to document.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxKitTests/EvaluatorEligibilityTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("Evaluator — eligibility and requirements") struct EvaluatorEligibilityTests {

    @Test("an unanswered question yields needsInfo, never ineligible")
    func unansweredQuestion() throws {
        let result = evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
        let spouse = try #require(result.assessment(for: ReliefCode("SPOUSE_ALIMONY")))
        guard case .needsInfo(let questions) = spouse.eligibility else {
            Issue.record("expected .needsInfo, got \(spouse.eligibility)"); return
        }
        #expect(questions.contains(.spouseHasIncome))
        // The cap is still shown, so the UI can say "unlock RM 4,000".
        #expect(spouse.cap == Money(ringgit: 4000))
    }

    @Test("answering the question makes the relief eligible")
    func answeredQuestion() throws {
        var year = Fixture.year()
        year.spouseHasIncome = false
        let result = evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
        #expect(result.assessment(for: ReliefCode("SPOUSE_ALIMONY"))?.eligibility == .eligible)
    }

    @Test("a definitively failing condition is ineligible with a readable reason")
    func failingCondition() throws {
        var year = Fixture.year()
        year.spouseHasIncome = true
        year.assessmentType = .separate
        let spouse = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
                .assessment(for: ReliefCode("SPOUSE_ALIMONY")))
        guard case .ineligible(let reasons) = spouse.eligibility else {
            Issue.record("expected .ineligible, got \(spouse.eligibility)"); return
        }
        #expect(reasons.isEmpty == false)
    }

    @Test("a relief outside its year range is ineligible, not merely absent")
    func outsideYearRange() throws {
        // HOUSING_LOAN_INTEREST is yaRange 2025-2027 and exists only in ya-2025.json,
        // so evaluating YA2025's rules against a 2028 snapshot must refuse it.
        var year = Fixture.year()
        year.year = 2028
        year.propertyPriceSen = Money(ringgit: 400_000).sen
        let housing = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST")))
        guard case .ineligible = housing.eligibility else {
            Issue.record("expected .ineligible, got \(housing.eligibility)"); return
        }
    }

    @Test("a claim with every required document passes its checks")
    func requirementsSatisfied() throws {
        let entry = Fixture.entry(ReliefCode("MEDICAL_SERIOUS"), 3000,
                                  documents: [.officialReceipt, .medicalCertificate])
        let medical = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [entry])
                .assessment(for: ReliefCode("MEDICAL_SERIOUS")))
        #expect(medical.requirements.count == 2)
        #expect(medical.requirements.allSatisfy(\.isSatisfied))
    }

    @Test("a missing document names the kind and the entries that lack it")
    func requirementMissing() throws {
        let entry = Fixture.entry(ReliefCode("MEDICAL_SERIOUS"), 3000,
                                  documents: [.officialReceipt])
        let medical = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [entry])
                .assessment(for: ReliefCode("MEDICAL_SERIOUS")))
        let failure = try #require(medical.requirements.first { !$0.isSatisfied })
        #expect(failure.kind == .medicalCertificate)
        #expect(failure.status == .missing(entryIDs: [entry.id]))
    }

    @Test("a relief with no entries has no requirement failures")
    func noEntriesNoFailures() throws {
        let medical = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
                .assessment(for: ReliefCode("MEDICAL_SERIOUS")))
        #expect(medical.requirements.allSatisfy(\.isSatisfied))
    }

    @Test("cap questions and predicate questions merge into one needsInfo list")
    func questionsMerge() throws {
        let housing = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST")))
        guard case .needsInfo(let questions) = housing.eligibility else {
            Issue.record("expected .needsInfo, got \(housing.eligibility)"); return
        }
        #expect(questions == [.propertyPrice])
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter EvaluatorEligibilityTests`
Expected: FAIL — `unansweredQuestion` gets `.eligible`, because Task 12 only reports cap
questions.

- [ ] **Step 3: Compute eligibility and requirements in `assess`**

In `Evaluator.swift`, replace the eligibility block from Task 12 with the following, and
change Task 11's `ownClaimed` line to reuse it —
`let ownClaimed = ownEntries.reduce(Money.zero) { $0 + $1.amount }` — moving the
`ownEntries` binding above it:

```swift
    let ownEntries = entriesByCode[rule.code] ?? []
    let ownClaimed = ownEntries.reduce(Money.zero) { $0 + $1.amount }
    let entered = children.reduce(ownClaimed) { $0 + $1.claimed }

    let resolved = effectiveCap(rule.cap, rule: rule, year: year)
    let cap = resolved.cap

    // Eligibility must be settled before the grant decision: an automatic relief is
    // granted only when it is actually eligible, never while a question is outstanding.
    let eligibility = resolveEligibility(rule: rule,
                                         year: year,
                                         capQuestions: resolved.missing)
    let requirements = checkRequirements(rule: rule, entries: ownEntries)

    let granted = rule.automatic && eligibility.isEligible
    let claimed = granted ? cap : entered
    let allowed = granted ? cap : entered.clamped(to: cap)
    let headroom = max(cap - allowed, .zero)
```

Delete Task 11's now-superseded `ownEntries` / `ownClaimed` / `entered` / `granted` block
and its `let eligibility = Eligibility.eligible` placeholder — the block above replaces
all of it.

and add these two functions to the file:

```swift
/// Combines the rule's predicate with any question the cap could not be resolved without.
///
/// A per-dependent rule is deliberately exempt from the household-level predicate check:
/// its predicate is about each dependent, and `effectiveCap` has already applied it
/// per dependent. Re-running it here with no dependent in context would report a
/// spurious `.needsInfo`.
private func resolveEligibility(rule: ReliefRule,
                                year: TaxYearSnapshot,
                                capQuestions: [ProfileQuestion]) -> Eligibility {
    let isPerDependent = if case .perDependent = rule.cap { true } else { false }

    guard let predicate = rule.eligibility, !isPerDependent else {
        return capQuestions.isEmpty ? .eligible : .needsInfo(questions: capQuestions)
    }

    switch predicate.evaluate(year.facts(claimant: nil)) {
    case .satisfied:
        return capQuestions.isEmpty ? .eligible : .needsInfo(questions: capQuestions)
    case .failed(let reason):
        return .ineligible(reasons: [reason])
    case .unknown(let questions):
        return .needsInfo(questions: (questions + capQuestions).deduplicated())
    }
}

/// Set difference of the documents attached to each entry against the kinds the rule
/// requires. This is the whole of the requirement-check feature.
private func checkRequirements(rule: ReliefRule,
                               entries: [EntrySnapshot]) -> [RequirementCheck] {
    rule.requiredDocuments.map { kind in
        let lacking = entries.filter { !$0.documentKinds.contains(kind) }.map(\.id)
        return RequirementCheck(kind: kind,
                                status: lacking.isEmpty ? .satisfied
                                                        : .missing(entryIDs: lacking))
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter EvaluatorEligibilityTests`
Expected: PASS, 8 tests.

Run: `swift test`
Expected: PASS, every suite.

If `EvaluatorCapKindTests.nonQualifyingDependentsExcluded` now fails, the per-dependent
exemption in `resolveEligibility` is missing — a child rule's predicate must not be run
against a household with no dependent in context.

- [ ] **Step 5: Commit**

```bash
git add Sources/TaxKit/Engine/Evaluator.swift Tests/TaxKitTests/EvaluatorEligibilityTests.swift
git commit -m "feat: compute three-state eligibility and documentary requirements"
```

---

### Task 14: Tax saved

**Files:**
- Modify: `Sources/TaxKit/Engine/Evaluator.swift`
- Modify: `Sources/TaxKit/Engine/ReliefAssessment.swift` (add `totalOpportunity`)
- Test: `Tests/TaxKitTests/TaxSavedTests.swift`

**Interfaces:**
- Consumes: `BracketTable.taxSaved` (Task 10), the evaluator (Tasks 11–13).
- Produces: `ReliefAssessment.taxSaved` populated, and
  `EvaluationResult.totalOpportunity: Money?`.

Three rules, each of which exists to stop the app overstating what it can deliver:

1. **`taxSaved` is `nil` unless income is known.** Not zero — `nil`, so the UI drops the
   column rather than showing RM 0.
2. **`nil` for an ineligible or unverified relief.** There is no saving from a relief the
   user cannot claim, and no honest figure from a cap that could not be verified against
   LHDN. A `.needsInfo` relief *does* get a figure, because that figure is the reason to
   answer the question.
3. **`totalOpportunity` is not the sum of the per-relief figures.** Each per-relief figure
   is computed at the same marginal point, so adding them double-counts the top band. The
   total is one `taxSaved` call against the combined headroom.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxKitTests/TaxSavedTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("Tax saved") struct TaxSavedTests {

    /// Gross RM 110,000 with only the automatic RM 9,000 relief leaves RM 101,000
    /// chargeable — just inside the 25% band. Lifestyle headroom of RM 2,500 straddles
    /// the RM 100,000 boundary, which is exactly the case a marginal-rate shortcut gets
    /// wrong.
    static func year() -> TaxYearSnapshot {
        Fixture.year(gross: Money(ringgit: 110_000))
    }

    @Test("no income means no tax figures at all")
    func noIncome() throws {
        let result = evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
        #expect(result.chargeableIncome == nil)
        #expect(result.estimatedTax == nil)
        #expect(result.totalOpportunity == nil)
        #expect(result.assessment(for: .lifestyle)?.taxSaved == nil)
    }

    @Test("chargeable income is gross less every allowed relief")
    func chargeableIncome() throws {
        let result = evaluate(ruleSet: try Fixture.rules(), year: Self.year(), entries: [])
        // Only SELF_AND_DEPENDENTS (RM 9,000) is allowed with no entries.
        #expect(result.chargeableIncome == Money(ringgit: 101_000))
        #expect(result.estimatedTax == try Fixture.rules().brackets
                                            .tax(on: Money(ringgit: 101_000)))
    }

    @Test("per-relief tax saved is the true difference across the boundary")
    func perReliefSaving() throws {
        let rules = try Fixture.rules()
        let result = evaluate(ruleSet: rules, year: Self.year(), entries: [])
        let lifestyle = try #require(result.assessment(for: .lifestyle))
        let expected = rules.brackets.taxSaved(reducing: Money(ringgit: 101_000),
                                               by: Money(ringgit: 2_500))
        #expect(lifestyle.taxSaved == expected)
        // 1,000 at 25% plus 1,500 at 19% = 250 + 285 = 535, not 2,500 x 25% = 625.
        #expect(expected == Money(ringgit: 535))
    }

    @Test("an ineligible relief has no saving")
    func ineligibleHasNoSaving() throws {
        var year = Self.year()
        year.spouseHasIncome = true
        year.assessmentType = .separate
        let spouse = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
                .assessment(for: ReliefCode("SPOUSE_ALIMONY")))
        #expect(spouse.taxSaved == nil)
    }

    @Test("a needsInfo relief still shows what answering is worth")
    func needsInfoStillShowsValue() throws {
        let spouse = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Self.year(), entries: [])
                .assessment(for: ReliefCode("SPOUSE_ALIMONY")))
        guard case .needsInfo = spouse.eligibility else {
            Issue.record("expected .needsInfo"); return
        }
        #expect(spouse.taxSaved != nil)
        #expect(spouse.taxSaved! > .zero)
    }

    @Test("a fully used relief has zero saving, not nil")
    func fullyUsedRelief() throws {
        let result = evaluate(ruleSet: try Fixture.rules(), year: Self.year(),
                              entries: [Fixture.entry(.lifestyle, 2500)])
        #expect(result.assessment(for: .lifestyle)?.headroom == .zero)
        #expect(result.assessment(for: .lifestyle)?.taxSaved == .zero)
    }

    @Test("total opportunity is one calculation, not a sum of the parts")
    func totalIsNotASum() throws {
        let rules = try Fixture.rules()
        let result = evaluate(ruleSet: rules, year: Self.year(), entries: [])
        let total = try #require(result.totalOpportunity)

        let naiveSum = result.assessments.compactMap(\.taxSaved).reduce(Money.zero, +)
        #expect(total < naiveSum, "summing per-relief figures double-counts the top band")

        let combinedHeadroom = result.assessments
            .filter { $0.taxSaved != nil }
            .reduce(Money.zero) { $0 + $1.headroom }
        #expect(total == rules.brackets.taxSaved(reducing: Money(ringgit: 101_000),
                                                 by: combinedHeadroom))
    }

    @Test("relief cannot save more tax than is owed")
    func cannotSaveMoreThanOwed() throws {
        let result = evaluate(ruleSet: try Fixture.rules(),
                              year: Fixture.year(gross: Money(ringgit: 20_000)),
                              entries: [])
        #expect(try #require(result.totalOpportunity) <= #require(result.estimatedTax))
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter TaxSavedTests`
Expected: FAIL — `value of type 'EvaluationResult' has no member 'totalOpportunity'`.

- [ ] **Step 3: Add `totalOpportunity` to the result type**

In `ReliefAssessment.swift`, add the stored property to `EvaluationResult` after
`estimatedTax`:

```swift
    /// The tax saved if every remaining headroom were used. Computed as one calculation
    /// against the combined headroom, because summing the per-relief figures would
    /// double-count the top band. `nil` when income is unknown.
    public var totalOpportunity: Money?
```

- [ ] **Step 4: Fill the figures in a second pass**

In `Evaluator.swift`, replace the income block at the end of `evaluate` with:

```swift
    guard let gross = year.grossIncome else { return result }

    let chargeable = max(gross - result.totalAllowed, .zero)
    result.chargeableIncome = chargeable
    result.estimatedTax = ruleSet.brackets.tax(on: chargeable)

    // Second pass: tax figures need the chargeable income the first pass produced.
    result.assessments = result.assessments.map {
        withTaxSaved($0, chargeable: chargeable, brackets: ruleSet.brackets)
    }
    let combinedHeadroom = result.assessments
        .filter { $0.taxSaved != nil }
        .reduce(Money.zero) { $0 + $1.headroom }
    result.totalOpportunity = ruleSet.brackets.taxSaved(reducing: chargeable,
                                                        by: combinedHeadroom)
    return result
}

/// Fills `taxSaved` on an assessment and its descendants.
///
/// Sub-limits get a figure too, but their headroom is already inside the parent's, so
/// only top-level assessments contribute to `totalOpportunity`.
private func withTaxSaved(_ assessment: ReliefAssessment,
                          chargeable: Money,
                          brackets: BracketTable) -> ReliefAssessment {
    var updated = assessment
    updated.children = assessment.children.map {
        withTaxSaved($0, chargeable: chargeable, brackets: brackets)
    }

    let claimable: Bool = switch assessment.eligibility {
    case .eligible, .needsInfo: true      // needsInfo shows what answering is worth
    case .ineligible: false
    }
    updated.taxSaved = (claimable && !assessment.unverified)
        ? brackets.taxSaved(reducing: chargeable, by: assessment.headroom)
        : nil
    return updated
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `swift test --filter TaxSavedTests`
Expected: PASS, 8 tests.

If `perReliefSaving` reports RM 625 instead of RM 535, `taxSaved` is using
`headroom.applying(marginalRate)` somewhere rather than `BracketTable.taxSaved`.

- [ ] **Step 6: Commit**

```bash
git add Sources/TaxKit/Engine Tests/TaxKitTests/TaxSavedTests.swift
git commit -m "feat: compute per-relief and combined tax saved"
```

---

### Task 15: Loading, year diffing, and the personalised counterfactual

**Files:**
- Create: `Sources/TaxKit/Rules/RuleSetLoading.swift`
- Create: `Sources/TaxKit/Rules/RuleSetDiff.swift`
- Create: `Sources/TaxKit/Engine/Counterfactual.swift`
- Test: `Tests/TaxKitTests/RuleSetDiffTests.swift`

**Interfaces:**
- Consumes: `RuleSet`, `evaluate`.
- Produces:
  - `protocol RuleSetLoading { func ruleSet(for year: Int) throws -> RuleSet; var availableYears: [Int] { get } }`
  - `struct BundledRuleSetLoader: RuleSetLoading`
  - `enum ReliefDelta` and `func diff(from:to:) -> [ReliefDelta]`
  - `struct CounterfactualLine`, `struct CounterfactualResult`,
    `func counterfactual(entries:year:under:versus:) -> CounterfactualResult`

The loader is a protocol so spec §13's remote-rules risk mitigation ("loader behind a
protocol so remote updates drop in without touching feature code") is real rather than
aspirational. Nothing downstream ever names `BundledRuleSetLoader`.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxKitTests/RuleSetDiffTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("Loading and diffing") struct RuleSetDiffTests {

    let loader = BundledRuleSetLoader()

    @Test("the bundled loader lists and loads every shipped year")
    func loaderLists() throws {
        #expect(loader.availableYears == [2023, 2024, 2025])
        #expect(try loader.ruleSet(for: 2024).yearOfAssessment == 2024)
    }

    @Test("an unshipped year throws rather than returning a wrong ruleset")
    func unknownYearThrows() {
        #expect(throws: RuleSetLoadingError.self) { try loader.ruleSet(for: 1999) }
    }

    @Test("the YA2024 to YA2025 diff reports every published change")
    func diff2024to2025() throws {
        let deltas = diff(from: try loader.ruleSet(for: 2024),
                          to: try loader.ruleSet(for: 2025))

        func capChange(_ code: String) -> (from: Money, to: Money)? {
            for case .capChanged(let c, _, let from, let to) in deltas
            where c == ReliefCode(code) { return (from, to) }
            return nil
        }

        #expect(capChange("DISABLED_SELF")?.to == Money(ringgit: 7000))
        #expect(capChange("DISABLED_SPOUSE")?.to == Money(ringgit: 6000))
        #expect(capChange("CHILD_DISABLED")?.to == Money(ringgit: 8000))
        #expect(capChange("MEDICAL_LEARNDIS")?.to == Money(ringgit: 6000))
        #expect(capChange("INSURANCE_EDU_MEDICAL")?.to == Money(ringgit: 4000))

        let added = deltas.compactMap { delta -> ReliefCode? in
            if case .added(let code, _, _) = delta { return code }
            return nil
        }
        #expect(added == [ReliefCode("HOUSING_LOAN_INTEREST")])
    }

    @Test("the YA2023 to YA2024 diff reports the two sub-limits that appear")
    func diff2023to2024() throws {
        let deltas = diff(from: try loader.ruleSet(for: 2023),
                          to: try loader.ruleSet(for: 2024))
        let added = Set(deltas.compactMap { delta -> ReliefCode? in
            if case .added(let code, _, _) = delta { return code }
            return nil
        })
        #expect(added == [ReliefCode("MEDICAL_DENTAL"), ReliefCode("PARENTS_CHECKUP")])
    }

    @Test("a removed relief reports its successor when one is declared")
    func removalReportsSuccessor() throws {
        let deltas = diff(from: try loader.ruleSet(for: 2025),
                          to: try loader.ruleSet(for: 2024))
        let removed = deltas.compactMap { delta -> ReliefCode? in
            if case .removed(let code, _, _) = delta { return code }
            return nil
        }
        #expect(removed == [ReliefCode("HOUSING_LOAN_INTEREST")])
    }

    @Test("diffing a ruleset against itself yields nothing")
    func selfDiffIsEmpty() throws {
        #expect(diff(from: try loader.ruleSet(for: 2025),
                     to: try loader.ruleSet(for: 2025)).isEmpty)
    }

    @Test("the counterfactual prices this year's spending under last year's rules")
    func counterfactualPricesTheChange() throws {
        var year = Fixture.year(2025, gross: Money(ringgit: 110_000))
        year.spouseHasIncome = false
        let entries = [Fixture.entry(ReliefCode("INSURANCE_EDU_MEDICAL"), 4000)]

        let result = counterfactual(entries: entries,
                                    year: year,
                                    under: try loader.ruleSet(for: 2025),
                                    versus: try loader.ruleSet(for: 2024))

        #expect(result.baselineYA == 2025)
        #expect(result.comparisonYA == 2024)

        let line = try #require(
            result.lines.first { $0.code == ReliefCode("INSURANCE_EDU_MEDICAL") })
        #expect(line.allowedUnderBaseline == Money(ringgit: 4000))
        #expect(line.allowedUnderComparison == Money(ringgit: 3000))
        #expect(line.difference == Money(ringgit: 1000))
    }

    @Test("unchanged reliefs do not clutter the counterfactual")
    func counterfactualOmitsUnchanged() throws {
        let result = counterfactual(entries: [Fixture.entry(.lifestyle, 500)],
                                    year: Fixture.year(2025),
                                    under: try loader.ruleSet(for: 2025),
                                    versus: try loader.ruleSet(for: 2024))
        #expect(result.lines.contains { $0.code == .lifestyle } == false)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter RuleSetDiffTests`
Expected: FAIL — `cannot find 'BundledRuleSetLoader' in scope`.

- [ ] **Step 3: Implement the loader**

Create `Sources/TaxKit/Rules/RuleSetLoading.swift`:

```swift
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
              let url = Bundle.module.url(forResource: "ya-\(year)",
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
```

- [ ] **Step 4: Implement the diff**

Create `Sources/TaxKit/Rules/RuleSetDiff.swift`:

```swift
import Foundation

/// One published change between two Years of Assessment.
public enum ReliefDelta: Hashable, Sendable {
    case added(ReliefCode, name: String, cap: Money)
    case removed(ReliefCode, name: String, supersededBy: ReliefCode?)
    case capChanged(ReliefCode, name: String, from: Money, to: Money)
    case conditionsChanged(ReliefCode, name: String, from: String?, to: String?)

    public var code: ReliefCode {
        switch self {
        case .added(let c, _, _), .removed(let c, _, _),
             .capChanged(let c, _, _, _), .conditionsChanged(let c, _, _, _): c
        }
    }
}

/// The rule-level difference between two rulebooks, in stable code order.
///
/// This is the generic diff. The figure users care about comes from
/// `counterfactual(entries:year:under:versus:)`, which prices these changes against their
/// own spending.
public func diff(from earlier: RuleSet, to later: RuleSet) -> [ReliefDelta] {
    let before = Dictionary(uniqueKeysWithValues: earlier.allReliefs.map { ($0.code, $0) })
    let after = Dictionary(uniqueKeysWithValues: later.allReliefs.map { ($0.code, $0) })
    let successors = Dictionary(later.retiredCodes.map { ($0.retired, $0.supersededBy) },
                                uniquingKeysWith: { first, _ in first })

    var deltas: [ReliefDelta] = []

    for code in after.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
        let new = after[code]!
        guard let old = before[code] else {
            deltas.append(.added(code, name: new.name, cap: new.cap.nominalCeiling))
            continue
        }
        if old.cap.nominalCeiling != new.cap.nominalCeiling {
            deltas.append(.capChanged(code, name: new.name,
                                      from: old.cap.nominalCeiling,
                                      to: new.cap.nominalCeiling))
        }
        if old.eligibility != new.eligibility || old.requiredDocuments != new.requiredDocuments {
            deltas.append(.conditionsChanged(code, name: new.name,
                                             from: old.notes, to: new.notes))
        }
    }

    for code in before.keys.sorted(by: { $0.rawValue < $1.rawValue }) where after[code] == nil {
        deltas.append(.removed(code, name: before[code]!.name,
                               supersededBy: successors[code] ?? nil))
    }
    return deltas
}
```

- [ ] **Step 5: Implement the counterfactual**

Create `Sources/TaxKit/Engine/Counterfactual.swift`:

```swift
import Foundation

/// One relief whose treatment differs between two rulebooks, priced against the user's
/// own entries.
public struct CounterfactualLine: Hashable, Sendable, Identifiable {
    public var code: ReliefCode
    public var name: String
    public var allowedUnderBaseline: Money
    public var allowedUnderComparison: Money
    /// Positive when the baseline year is better for this user.
    public var difference: Money

    public var id: ReliefCode { code }
}

public struct CounterfactualResult: Hashable, Sendable {
    public var baselineYA: Int
    public var comparisonYA: Int
    /// Only reliefs whose allowed amount actually differs, biggest difference first.
    public var lines: [CounterfactualLine]
    public var totalReliefDifference: Money
    /// Difference in estimated tax. `nil` when income is unknown.
    public var taxDifference: Money?
}

/// Replays the same entries under two rulebooks and reports the difference in ringgit.
///
/// This is the version of year comparison worth showing: not "the cap went up" but
/// "the cap going up is worth RM 1,680 to you". It costs almost nothing to build because
/// `evaluate` is pure — the only change is which ruleset is passed in.
public func counterfactual(entries: [EntrySnapshot],
                           year: TaxYearSnapshot,
                           under baseline: RuleSet,
                           versus comparison: RuleSet) -> CounterfactualResult {

    let base = evaluate(ruleSet: baseline, year: year, entries: entries)
    let other = evaluate(ruleSet: comparison, year: year, entries: entries)

    let otherByCode = Dictionary(uniqueKeysWithValues:
        other.allAssessments.map { ($0.code, $0) })

    var lines: [CounterfactualLine] = []
    for assessment in base.allAssessments {
        let comparisonAllowed = otherByCode[assessment.code]?.allowed ?? .zero
        guard assessment.allowed != comparisonAllowed else { continue }
        lines.append(CounterfactualLine(
            code: assessment.code,
            name: assessment.name,
            allowedUnderBaseline: assessment.allowed,
            allowedUnderComparison: comparisonAllowed,
            difference: assessment.allowed - comparisonAllowed))
    }

    // A relief that exists only in the comparison year is a loss under the baseline.
    let baseCodes = Set(base.allAssessments.map(\.code))
    for assessment in other.allAssessments where !baseCodes.contains(assessment.code) {
        guard assessment.allowed != .zero else { continue }
        lines.append(CounterfactualLine(
            code: assessment.code,
            name: assessment.name,
            allowedUnderBaseline: .zero,
            allowedUnderComparison: assessment.allowed,
            difference: Money.zero - assessment.allowed))
    }

    lines.sort { abs($0.difference.sen) > abs($1.difference.sen) }

    var taxDifference: Money?
    if let baseTax = base.estimatedTax, let otherTax = other.estimatedTax {
        taxDifference = otherTax - baseTax
    }

    return CounterfactualResult(
        baselineYA: baseline.yearOfAssessment,
        comparisonYA: comparison.yearOfAssessment,
        lines: lines,
        totalReliefDifference: lines.reduce(Money.zero) { $0 + $1.difference },
        taxDifference: taxDifference)
}
```

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `swift test --filter RuleSetDiffTests`
Expected: PASS, 8 tests.

If `diff2024to2025` reports extra `conditionsChanged` entries, that is expected for
`PARENTS_MEDICAL`, `LIFESTYLE_SPORTS` and `MEDICAL_CHECKUP` — their eligibility or notes
did change. The test only asserts on cap changes and additions.

- [ ] **Step 7: Commit**

```bash
git add Sources/TaxKit/Rules Sources/TaxKit/Engine/Counterfactual.swift Tests/TaxKitTests/RuleSetDiffTests.swift
git commit -m "feat: add rule loading, year diffing, and the personalised counterfactual"
```

---

### Task 16: Golden-file regression suite

**Files:**
- Modify: `Sources/TaxKit/Engine/ReliefAssessment.swift` (add `Codable`)
- Create: `Tests/TaxKitTests/GoldenFileTests.swift`
- Create: `Tests/TaxKitTests/Fixtures/golden-ya2023.json` (recorded)
- Create: `Tests/TaxKitTests/Fixtures/golden-ya2024.json` (recorded)
- Create: `Tests/TaxKitTests/Fixtures/golden-ya2025.json` (recorded)
- Delete: `Tests/TaxKitTests/Fixtures/.keep.json`

**Interfaces:**
- Consumes: the whole engine.
- Produces: a checked-in snapshot of one realistic household's full assessment under each
  shipped year, so any future change to a cap, a predicate or the engine shows up as a
  reviewable diff rather than a silent behaviour change.

The unit tests assert specific behaviours. The golden files catch the thing unit tests
miss: an unintended change somewhere else in the rulebook. They only work if the engine is
deterministic, which is why `evaluate` takes no dates, no randomness and no I/O — and why
the persona below uses fixed UUIDs.

- [ ] **Step 1: Make the result types Codable**

In `Sources/TaxKit/Engine/ReliefAssessment.swift`, add `Codable` to the conformance list of
`Eligibility`, `RequirementCheck`, `RequirementCheck.Status`, `ReliefAssessment`,
`UnresolvedEntry`, `UnresolvedEntry.Reason` and `EvaluationResult`. Swift synthesises
`Codable` for enums with associated values, so no manual implementations are needed.

Verify it compiles before going further:

```bash
swift build
```

- [ ] **Step 2: Write the failing test**

Create `Tests/TaxKitTests/GoldenFileTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxKit

@Suite("Golden files") struct GoldenFileTests {

    /// A married Kuala Lumpur salaryman with three children and a first home.
    /// Deliberately exercises fixed caps, sub-limits, per-dependent caps, tiered caps,
    /// a satisfied requirement, a missing requirement and an unresolved code.
    enum Persona {
        static func id(_ n: Int) -> UUID {
            UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
        }

        static let children = [
            DependentSnapshot(id: id(101), name: "Aisyah", ageAtYearEnd: 7,
                              educationLevel: EducationLevel.none, claimPercentage: 100),
            DependentSnapshot(id: id(102), name: "Danish", ageAtYearEnd: 19,
                              educationLevel: .tertiaryLocal, claimPercentage: 100),
            DependentSnapshot(id: id(103), name: "Farah", ageAtYearEnd: 16,
                              educationLevel: .preTertiary, claimPercentage: 50)
        ]

        static func year(_ ya: Int) -> TaxYearSnapshot {
            TaxYearSnapshot(year: ya,
                            grossIncome: Money(ringgit: 128_000),
                            maritalStatus: .married,
                            spouseHasIncome: false,
                            assessmentType: .separate,
                            employmentType: .privateSector,
                            gender: .female,
                            dependents: children,
                            propertyPriceSen: Money(ringgit: 480_000).sen,
                            lastClaimedYear: [:])
        }

        static let entries: [EntrySnapshot] = [
            EntrySnapshot(id: id(1), code: .lifestyle, amount: Money(ringgit: 1_820),
                          documentKinds: [.officialReceipt]),
            EntrySnapshot(id: id(2), code: ReliefCode("LIFESTYLE_SPORTS"),
                          amount: Money(ringgit: 1_400), documentKinds: [.officialReceipt]),
            EntrySnapshot(id: id(3), code: ReliefCode("MEDICAL_SERIOUS"),
                          amount: Money(ringgit: 6_500),
                          documentKinds: [.officialReceipt, .medicalCertificate]),
            EntrySnapshot(id: id(4), code: ReliefCode("MEDICAL_CHECKUP"),
                          amount: Money(ringgit: 900), documentKinds: [.officialReceipt]),
            EntrySnapshot(id: id(5), code: ReliefCode("EPF_CONTRIBUTION"),
                          amount: Money(ringgit: 4_600), documentKinds: [.epfStatement]),
            EntrySnapshot(id: id(6), code: ReliefCode("LIFE_INSURANCE"),
                          amount: Money(ringgit: 2_100), documentKinds: []),   // missing doc
            EntrySnapshot(id: id(7), code: ReliefCode("SSPN"),
                          amount: Money(ringgit: 3_000), documentKinds: [.bankStatement]),
            EntrySnapshot(id: id(8), code: ReliefCode("CHILDCARE"),
                          amount: Money(ringgit: 2_400), dependentID: id(101),
                          documentKinds: [.officialReceipt]),
            EntrySnapshot(id: id(9), code: ReliefCode("HOUSING_LOAN_INTEREST"),
                          amount: Money(ringgit: 9_100), documentKinds: [.bankStatement]),
            EntrySnapshot(id: id(10), code: ReliefCode("SOCSO_EIS"),
                          amount: Money(ringgit: 350), documentKinds: [])
        ]
    }

    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures")
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    @Test("the persona's assessment matches the recorded golden file",
          arguments: [2023, 2024, 2025])
    func matchesGolden(year: Int) throws {
        let rules = try BundledRuleSetLoader().ruleSet(for: year)
        let result = evaluate(ruleSet: rules,
                              year: Persona.year(year),
                              entries: Persona.entries)
        let produced = try Self.encoder().encode(result)
        let file = Self.fixturesDirectory.appending(path: "golden-ya\(year).json")

        // Re-record with: TAXKIT_RECORD=1 swift test --filter GoldenFileTests
        if ProcessInfo.processInfo.environment["TAXKIT_RECORD"] == "1" {
            try produced.write(to: file)
            return
        }

        let expected = try #require(try? Data(contentsOf: file),
                                    "golden-ya\(year).json missing — record it first")
        #expect(String(data: produced, encoding: .utf8)
                == String(data: expected, encoding: .utf8))
    }

    @Test("the persona is realistic enough to exercise the whole engine")
    func personaCoversTheEngine() throws {
        let result = evaluate(ruleSet: try BundledRuleSetLoader().ruleSet(for: 2025),
                              year: Persona.year(2025),
                              entries: Persona.entries)

        // Over-claimed against a fixed cap.
        #expect(result.assessment(for: ReliefCode("LIFESTYLE_SPORTS"))?.allowed
                == Money(ringgit: 1_000))
        // Sub-limit inside a parent ceiling.
        #expect(result.assessment(for: ReliefCode("MEDICAL_CHECKUP"))?.allowed
                == Money(ringgit: 900))
        // Per-dependent cap: one under-18 at 100%, one pre-tertiary 16-year-old is
        // under 18 too, one tertiary 19-year-old is not.
        #expect(result.assessment(for: ReliefCode("CHILD_TERTIARY"))?.cap
                == Money(ringgit: 8_000))
        // Tiered cap: RM 480,000 home selects the RM 7,000 tier.
        #expect(result.assessment(for: ReliefCode("HOUSING_LOAN_INTEREST"))?.cap
                == Money(ringgit: 7_000))
        // A missing document is reported.
        let life = try #require(result.assessment(for: ReliefCode("LIFE_INSURANCE")))
        #expect(life.requirements.contains { !$0.isSatisfied })
        // Income figures are present.
        #expect(result.chargeableIncome != nil)
        #expect(result.totalOpportunity != nil)
    }

    @Test("the same persona under YA2024 loses the housing relief to unresolved")
    func housingUnresolvedInEarlierYears() throws {
        let result = evaluate(ruleSet: try BundledRuleSetLoader().ruleSet(for: 2024),
                              year: Persona.year(2024),
                              entries: Persona.entries)
        #expect(result.unresolved.contains {
            $0.code == ReliefCode("HOUSING_LOAN_INTEREST")
                && $0.reason == .unknownInThisYear
        })
    }

    @Test("golden files are deterministic across repeated evaluation",
          arguments: [2023, 2024, 2025])
    func evaluationIsDeterministic(year: Int) throws {
        let rules = try BundledRuleSetLoader().ruleSet(for: year)
        let first = evaluate(ruleSet: rules, year: Persona.year(year), entries: Persona.entries)
        let second = evaluate(ruleSet: rules, year: Persona.year(year), entries: Persona.entries)
        #expect(first == second)
    }
}
```

- [ ] **Step 3: Run the test and confirm it fails**

```bash
rm Tests/TaxKitTests/Fixtures/.keep.json
swift test --filter GoldenFileTests
```

Expected: FAIL — `golden-ya2023.json missing — record it first`.

- [ ] **Step 4: Record the golden files, then read them**

```bash
TAXKIT_RECORD=1 swift test --filter GoldenFileTests
```

**Read all three recorded files before committing.** This is the step that makes the whole
suite worth having: a golden file recorded without being read only locks in whatever the
code happened to do. Check specifically that

- `chargeableIncome` is gross RM 128,000 minus the allowed reliefs,
- no relief shows `allowed` above its `cap`,
- `LIFESTYLE_SPORTS` shows `claimed` RM 1,400 and `allowed` RM 1,000,
- YA2025 has a `HOUSING_LOAN_INTEREST` assessment and YA2024 has it in `unresolved`,
- every `taxSaved` is either `null` or no larger than `estimatedTax`.

If any of those is wrong, the bug is in the engine, not the fixture. Fix the engine and
re-record.

- [ ] **Step 5: Run the full suite and confirm it passes**

```bash
swift test
```

Expected: PASS, every suite — roughly 90 tests across 12 suites.

- [ ] **Step 6: Commit**

```bash
git add Sources/TaxKit/Engine/ReliefAssessment.swift Tests/TaxKitTests
git commit -m "test: add golden-file regression suite for a realistic household"
```

---

## Definition of done

Plan 1 is complete when all of the following hold:

- [ ] `swift build` succeeds with no warnings under Swift 6 language mode.
- [ ] `swift test` passes every suite.
- [ ] `grep -rn "Double" Sources/TaxKit --include=*.swift` returns only
      `lossyDoubleForCharting` and its doc comment.
- [ ] `swift package --allow-writing-to-package-directory generate-relief-codes` produces
      no diff.
- [ ] Every relief in every shipped ruleset carries a `hasil.gov.my` `sourceURL` and a
      `verifiedOn` date.
- [ ] No amount reaches user-facing text without the formatter. Inspect every hit of
      `grep -rn '\\(' Sources/TaxKit --include=*.swift | grep -E 'sen|amount|headroom|allowed|claimed'`
      and confirm each is a `precondition` or `DecodingError` diagnostic, never UI copy.
- [ ] `evaluate` has no dependency on `Date()`, `Bundle` (outside the loader), SwiftData,
      or SwiftUI.

Plan 2 (persistence, sync, iOS shell) consumes `Money`, `ReliefCode`, `RuleSetLoading`,
`TaxYearSnapshot`, `EntrySnapshot`, `evaluate` and `EvaluationResult`, and nothing else
from this package.
