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
- One formatter only: `Money.formatted()` produces `RM 2,500.00`. Interpolating an amount into a string anywhere else is a defect.
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
    Money+Formatting.swift                 the single ms_MY formatter
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
  - `Cap` — `.fixed(Money)`, `.sharedPool(id: String, Money)`, `.perDependent(Money)`,
    `.tiered(on: TieredFact, tiers: [Tier])`, `.none`; plus `Tier`, `TieredFact`.
  - `ReliefRule` — `code`, `name`, `cap`, `requiredDocuments`, `children`, `sourceURL`,
    `unverified`, `notes`. Task 7 adds the `eligibility` property.
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
          "code": "INSURANCE_LIFE",
          "name": "Life insurance",
          "cap": { "kind": "sharedPool", "poolID": "LIFE_EPF", "sen": 300000 },
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/"
        },
        {
          "code": "CHILD_UNDER_18",
          "name": "Child under 18",
          "cap": { "kind": "perDependent", "sen": 200000 },
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
        #expect(reliefs[1].cap == .sharedPool(id: "LIFE_EPF", Money(sen: 300_000)))
        #expect(reliefs[2].cap == .perDependent(Money(sen: 200_000)))
        #expect(reliefs[3].cap == .tiered(on: .propertyPrice, tiers: [
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
    }

    @Test("required documents decode as typed kinds")
    func documentKinds() throws {
        #expect(try decoded().reliefs[0].requiredDocuments == [.officialReceipt, .medicalCertificate])
    }

    @Test("allReliefs flattens children depth-first")
    func flattening() throws {
        let codes = try decoded().allReliefs.map(\.code.rawValue)
        #expect(codes == ["MEDICAL_SERIOUS", "MEDICAL_DENTAL", "INSURANCE_LIFE",
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
    /// A ceiling shared with every other relief carrying the same pool identifier.
    /// The pool's own ceiling is the largest amount declared by its members.
    case sharedPool(id: String, Money)
    /// A ceiling that applies once per eligible dependent.
    case perDependent(Money)
    /// A ceiling selected by a fact about the claim.
    case tiered(on: TieredFact, tiers: [Tier])
    /// No ceiling. Reserved; no shipped relief uses it.
    case none

    private enum CodingKeys: String, CodingKey { case kind, sen, poolID, on, tiers }
    private enum Kind: String, Codable { case fixed, sharedPool, perDependent, tiered, none }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .fixed:
            self = .fixed(Money(sen: try c.decode(Int.self, forKey: .sen)))
        case .sharedPool:
            self = .sharedPool(id: try c.decode(String.self, forKey: .poolID),
                               Money(sen: try c.decode(Int.self, forKey: .sen)))
        case .perDependent:
            self = .perDependent(Money(sen: try c.decode(Int.self, forKey: .sen)))
        case .tiered:
            self = .tiered(on: try c.decode(TieredFact.self, forKey: .on),
                           tiers: try c.decode([Tier].self, forKey: .tiers))
        case .none:
            self = .none
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fixed(let amount):
            try c.encode(Kind.fixed, forKey: .kind)
            try c.encode(amount.sen, forKey: .sen)
        case .sharedPool(let id, let amount):
            try c.encode(Kind.sharedPool, forKey: .kind)
            try c.encode(id, forKey: .poolID)
            try c.encode(amount.sen, forKey: .sen)
        case .perDependent(let amount):
            try c.encode(Kind.perDependent, forKey: .kind)
            try c.encode(amount.sen, forKey: .sen)
        case .tiered(let fact, let tiers):
            try c.encode(Kind.tiered, forKey: .kind)
            try c.encode(fact, forKey: .on)
            try c.encode(tiers, forKey: .tiers)
        case .none:
            try c.encode(Kind.none, forKey: .kind)
        }
    }

    /// The largest amount this cap can ever allow, ignoring per-dependent multiplicity.
    /// Used for display and for ordering opportunities.
    public var nominalCeiling: Money {
        switch self {
        case .fixed(let amount), .sharedPool(_, let amount), .perDependent(let amount):
            return amount
        case .tiered(_, let tiers):
            return tiers.map(\.amount).max() ?? .zero
        case .none:
            return Money(sen: .max)
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
    public let requiredDocuments: [DocumentKind]
    /// Sub-limits. A child's claims also count against this relief's cap.
    public let children: [ReliefRule]
    public let sourceURL: URL
    /// Set when a figure could not be verified against hasil.gov.my. Excluded from
    /// tax-saved maths and rendered with a "verify with LHDN" note.
    public let unverified: Bool
    public let notes: String?

    private enum CodingKeys: String, CodingKey {
        case code, name, cap, requiredDocuments, children, sourceURL, unverified, notes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try c.decode(ReliefCode.self, forKey: .code)
        self.name = try c.decode(String.self, forKey: .name)
        self.cap = try c.decode(Cap.self, forKey: .cap)
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

    public init(yearOfAssessment: Int,
                maritalStatus: MaritalStatus? = nil,
                spouseHasIncome: Bool? = nil,
                assessmentType: AssessmentType? = nil,
                employmentType: EmploymentType? = nil,
                gender: Gender? = nil,
                claimant: Claimant? = nil,
                dependent: DependentFacts? = nil,
                claimHistory: ClaimHistory = .unknown,
                propertyPriceSen: Int? = nil) {
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
        case code, name, cap, requiredDocuments, eligibility, children, sourceURL, unverified, notes
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
  sub-limit and a RM 3,000 life/takaful sub-limit. That is a parent cap with two children,
  not a shared pool. `Cap.sharedPool` stays in the model for a future YA that needs it and
  is exercised by Task 6's decoding test; no YA2023–2025 relief uses it.
- **LHDN items 6, 7 and 8** are three rows that all draw on one RM 10,000 ceiling, so they
  are modelled as one parent (`MEDICAL_SERIOUS`) with four sub-limits.

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
      "notes": "Granted automatically.",
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
      "notes": "YA2024 was RM 6,000.",
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
      "eligibility": { "op": "any", "of": [
        { "op": "spouseHasIncome", "is": false },
        { "op": "assessmentType", "is": "joint" }
      ] },
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "DISABLED_SPOUSE", "name": "Disabled spouse",
      "cap": { "kind": "fixed", "sen": 600000 },
      "notes": "YA2024 was RM 5,000.",
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
      "eligibility": { "op": "all", "of": [
        { "op": "claimant", "in": ["child"] },
        { "op": "dependentAge", "min": 18 },
        { "op": "dependentEducation", "in": ["preTertiary"] }
      ] },
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "CHILD_TERTIARY",
      "name": "Child 18 and over in full-time tertiary study",
      "cap": { "kind": "perDependent", "sen": 800000 },
      "eligibility": { "op": "all", "of": [
        { "op": "claimant", "in": ["child"] },
        { "op": "dependentAge", "min": 18 },
        { "op": "dependentEducation", "in": ["tertiaryLocal", "tertiaryOverseas"] }
      ] },
      "notes": "Local diploma and above, or overseas degree and above, at a recognised institution. Excludes matriculation, pre-degree and A-Level.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "CHILD_DISABLED", "name": "Disabled child",
      "cap": { "kind": "perDependent", "sen": 800000 },
      "eligibility": { "op": "all", "of": [
        { "op": "claimant", "in": ["child"] },
        { "op": "dependentIsDisabled", "is": true }
      ] },
      "notes": "YA2024 was RM 6,000.",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/" },

    { "code": "CHILD_DISABLED_TERTIARY",
      "name": "Disabled child 18 and over in recognised tertiary study",
      "cap": { "kind": "perDependent", "sen": 800000 },
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
