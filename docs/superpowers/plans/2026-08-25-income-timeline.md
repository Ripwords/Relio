# Income Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `TaxYear`'s single gross-income figure with effective-dated income sources, so a raise, a job change or side income is recorded once as it happens and the year's total is derived rather than retyped.

**Architecture:** Two new `@Model` types in `TaxData` hold named income sources and their records. The derivation is a **pure function over `Sendable` value types**, not a method on `TaxStore` — the same split that makes `TaxKit`'s evaluator testable without a simulator, applied one layer up: `TaxStore` projects models into snapshots, the pure function turns snapshots into a `Money`, and the projection feeds that to the engine. **`TaxKit` is not modified.** Everything here sits upstream of the single `grossIncome` the engine already consumes.

**Tech Stack:** Swift 6.3, SwiftPM (tools 6.2), SwiftData, Observation, SwiftUI, swift-testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-08-25-income-timeline-design.md`

**Predecessors:** Plan 1 (`2026-08-23-taxkit-foundation-and-rules-engine.md`) built the engine; Plan 2 (`2026-08-24-persistence-sync-and-ios-shell.md`) built persistence, the view models and the app. 305 tests pass at the start of this plan.

## Global Constraints

Every constraint from Plans 1 and 2 still applies. Repeated because an implementer reads
this section and their own task, and nothing else:

- Swift tools `6.2`; Swift 6 language mode; strict concurrency; platforms iOS/macOS/watchOS 26. No `@unchecked Sendable`.
- **No `Double` in any calculation path.** The only `Double` in the package is `Money.lossyDoubleForCharting`; the only one in the app is `ProgressView(value:total:)` at the render boundary. **The derivation in this plan is a calculation path feeding chargeable income** — percentages go through `Money.applying(_:rounding:)` with a `Decimal`.
- Money is whole sen. One formatter: `Money.formatted()`.
- **`TaxKit` stays pure and must not be modified by this plan** — no SwiftData, no SwiftUI, no source changes at all.
- **`TaxPresentation` must not import SwiftUI.**
- **Every write goes through `TaxStore`**, which stamps `updatedAt` from its injected clock. No `@Model` object escapes the actor; every value crossing that boundary is a `Sendable` value type.
- **Every `@Model` attribute is optional or defaulted; every relationship optional; no `@Attribute(.unique)`.** Enforced by `SchemaInvariantTests`, which walks `SchemaV1.models`.
- **Soft delete everywhere** (`deletedAt: Date?`); every read filters `deletedAt == nil`.
- **No `Date()` inside a computation.** The derivation takes the year as a parameter, exactly as `AgeCalculator` does, so its results cannot rot on 1 January.
- **Dates resolve in `Asia/Kuala_Lumpur` on a `.gregorian` calendar with a POSIX locale.** Two devices in different zones must derive the same figure.
- **Ordering is total** — value, then `id.uuidString` — wherever two devices must converge independently.
- **Unknown stays unknown.** A `Bool?` that is `nil` means "not asked"; storing `false` is how an app silently refuses a relief and never explains why.
- TDD: the failing test is written and observed failing before the implementation, in every task.
- Conventional Commits.

## The worked example this plan is verified against

Used by Tasks 3, 4 and 5, and pinned in the spec:

```
Main job
  1 Jan 2025   RM 8,000 / month
  15 Apr 2025  RM 9,500 / month      ← mid-MONTH raise

  Jan, Feb, Mar   3 × 8,000.00              = 24,000.00
  Apr             1–14 @ 8,000 × 14/30      =  3,733.33
                  15–30 @ 9,500 × 16/30     =  5,066.67
                                April total =  8,800.00
  May–Dec         8 × 9,500.00              = 76,000.00
                                              ──────────
                                              108,800.00
Side work (one-off)
  14 Mar RM 1,800 · 2 Jul RM 2,400 · 9 Nov RM 950   =  5,150.00
                                              ──────────
  Gross income for YA2025                       113,950.00
```

April is the case that matters: the two halves round in **opposite** directions — down to
3,733.33 and up to 5,066.67 — and still sum to exactly 8,800.00. An implementation that
rounds once at the end, or truncates, produces a different number and passes a test that
only checks whole months.

## File Structure

```
Sources/TaxData/
  Models/
    IncomeSource.swift            IncomeSource, IncomeKind
    IncomeRecord.swift            IncomeRecord, IncomeShape
    TaxYear.swift                 MODIFIED — loses epfSen/socsoSen, renames the gross field
  Income/
    IncomeCalendar.swift          day-level KL calendar arithmetic
    IncomeSnapshots.swift         IncomeSourceSnapshot, IncomeRecordSnapshot (Sendable)
    IncomeDerivation.swift        the pure derivation — no SwiftData, no store
  Store/
    TaxStore+Income.swift         drafts, write path, reads, model → snapshot
    TaxStore.swift                MODIFIED — YearFacts loses epf/socso, gains the override
  Schema/SchemaV1.swift           MODIFIED — two more models
  Projection/Projection.swift     MODIFIED — override ?? derived

Sources/TaxPresentation/
  IncomeViewModel.swift           the Income screen's state
  OnboardingViewModel.swift       MODIFIED — writes a source, not a year total

App/TaxTracker/
  Income/IncomeView.swift         sources, history, derived total, override
  Onboarding/OnboardingView.swift MODIFIED — asks salary + start date
  RootView.swift                  MODIFIED — Income destination

Tests/TaxDataTests/
  IncomeModelTests.swift          defaults, three-valued deductions, relationships
  IncomeCalendarTests.swift       day spans, month lengths, leap year
  IncomeDerivationTests.swift     the heart — every boundary case
  IncomeStoreTests.swift          write path, reads, ordering
Tests/TaxPresentationTests/
  IncomeViewModelTests.swift
```

---

### Task 1: The two models and the schema

**Files:**
- Create: `Sources/TaxData/Models/IncomeSource.swift`, `Sources/TaxData/Models/IncomeRecord.swift`
- Modify: `Sources/TaxData/Schema/SchemaV1.swift`
- Test: `Tests/TaxDataTests/IncomeModelTests.swift`

**Interfaces:**
- Consumes: `Money` from `TaxKit`; the existing model conventions.
- Produces: `@Model final class IncomeSource`, `enum IncomeKind`, `@Model final class IncomeRecord`, `enum IncomeShape`.

**Why `SchemaV1` is amended rather than bumped to V2.** Spec §9: `SchemaV1` has not shipped
to any user, so this is free exactly once. After release the same change needs a
`MigrationStage`. `TaxMigrationPlan` keeps its single version and empty stage list.

**Why one record type with a shape discriminator.** Spec §4. It keeps the mirrored
relationship graph flat — the same reasoning that put `DependentYearStatus` inline on
`Dependent` rather than making it an entity. `effectiveFrom` means "the date this rate takes
effect" for a `recurring` record and "the date the money arrived" for a `oneOff`; one dated
field with a documented meaning per shape beats two of which one is always nil.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxDataTests/IncomeModelTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
import TaxKit
@testable import TaxData

@Suite("Income models") struct IncomeModelTests {

    @Test("a fresh source is unanswered rather than assumed")
    func freshSourceIsUnanswered() {
        let source = IncomeSource(name: "Main job")
        #expect(source.name == "Main job")
        #expect(source.kind == .employment)
        #expect(source.endedOn == nil)
        #expect(source.deletedAt == nil)
        #expect(source.updatedAt == .distantPast)
        // nil, not false. A second employment deducts EPF and SOCSO; occasional 4(f)
        // income does not; and employment does not guarantee it either. Storing false for
        // a question nobody asked is how an app silently refuses a relief.
        #expect(source.deductsEPF == nil)
        #expect(source.deductsSOCSO == nil)
    }

    @Test("kind round-trips through raw storage and degrades safely")
    func kindRoundTrips() {
        let source = IncomeSource(name: "Design freelance")
        source.kind = .occasional
        #expect(source.kindRaw == "occasional")
        #expect(source.kind == .occasional)

        // A value from a future build must not trap; it reads as `other`, which is the
        // kind that warns rather than the kind that stays silent.
        source.kindRaw = "cryptoMining"
        #expect(source.kind == .other)
    }

    @Test("a record round-trips its amount and shape")
    func recordRoundTrips() {
        let record = IncomeRecord()
        record.shape = .recurring
        record.amount = Money(ringgit: 8_000)
        #expect(record.shapeRaw == "recurring")
        #expect(record.amountSen == 800_000)
        #expect(record.amount == Money(ringgit: 8_000))

        record.shape = .oneOff
        #expect(record.shape == .oneOff)
    }

    @Test("records belong to a source and the source lists them")
    func sourceRecordInverse() throws {
        let container = try TaxContainer.make(.inMemory)
        let context = ModelContext(container)

        let source = IncomeSource(name: "Main job")
        let january = IncomeRecord()
        january.shape = .recurring
        january.amount = Money(ringgit: 8_000)
        january.source = source
        context.insert(source)
        context.insert(january)
        try context.save()

        #expect(source.records?.count == 1)
        #expect(source.records?.first?.amount == Money(ringgit: 8_000))
        #expect(january.source?.name == "Main job")
    }

    @Test("liveRecords excludes soft-deleted ones")
    func liveRecordsFilter() throws {
        let container = try TaxContainer.make(.inMemory)
        let context = ModelContext(container)
        let source = IncomeSource(name: "Main job")
        let kept = IncomeRecord(); kept.source = source
        let removed = IncomeRecord(); removed.source = source
        removed.deletedAt = Date(timeIntervalSince1970: 1)
        for object in [source] { context.insert(object) }
        for object in [kept, removed] { context.insert(object) }
        try context.save()

        // A deleted raise that still counted would silently inflate the year's income.
        #expect(source.liveRecords.count == 1)
        #expect(source.liveRecords.first?.id == kept.id)
    }

    @Test("both new models are CloudKit-mirroring-safe")
    func mirroringSafe() {
        let problems = SchemaInvariants.violations(in: Schema(SchemaV1.models))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("SchemaV1 now lists nine models")
    func schemaIsComplete() {
        let names = Set(SchemaV1.models.map { String(describing: $0) })
        #expect(names == ["TaxYear", "Dependent", "ReliefEntry", "Document", "DocumentFile",
                          "ChatMessage", "UserPreferences", "IncomeSource", "IncomeRecord"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter IncomeModel`
Expected: FAIL — "cannot find 'IncomeSource' in scope".

- [ ] **Step 3: Write `IncomeSource`**

Create `Sources/TaxData/Models/IncomeSource.swift`:

```swift
import Foundation
import SwiftData
import TaxKit

/// What kind of income a source pays, which decides what Relio is allowed to claim about
/// it. It does NOT imply statutory deductions and does not gate any arithmetic — see
/// `deductsEPF`. Spec §4.
public enum IncomeKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// A job. Aggregates into chargeable income on Form BE.
    case employment
    /// Part-time or occasional work — ITA 1967 §4(f) "other gains or profits".
    /// Declared on Form BE under other gains and profits, so it aggregates too.
    case occasional
    /// Carried on as a business, in practice registered with SSM. Belongs on Form B,
    /// where expenses are deductible. Relio's figure is not the figure you file.
    case business
    /// Rental. Expenses are deductible, so pooling gross rent overstates.
    case rental
    /// Anything else, including a value from a future build this one cannot read.
    case other
}

/// One stream of income — a job, a side gig — with its own history.
///
/// Deliberately global rather than hanging off `TaxYear`: a salary set in April 2024 is
/// still in force in January 2025. Per-year sources would force the user to re-enter an
/// unchanged salary every January, which is the problem this design exists to remove.
@Model
public final class IncomeSource {

    public var id: UUID = UUID()
    public var name: String = ""
    public var kindRaw: String = IncomeKind.employment.rawValue

    /// `nil` means "not asked yet", which the UI turns into a prompt. `false` would mean
    /// "confirmed no deductions" — a different claim, and one nobody made. Spec §7.
    public var deductsEPF: Bool?
    public var deductsSOCSO: Bool?

    /// The last day this source paid, inclusive. The only thing that can stop a recurring
    /// rate — leaving a job has no record of its own.
    public var endedOn: Date?

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \IncomeRecord.source)
    public var records: [IncomeRecord]?

    public init(id: UUID = UUID(), name: String = "") {
        self.id = id
        self.name = name
    }
}

extension IncomeSource {

    /// An unreadable raw value reads as `.other`, which is the kind that warns rather than
    /// the kind that stays silent — the safe direction for income Relio may not model.
    public var kind: IncomeKind {
        get { IncomeKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    public var liveRecords: [IncomeRecord] {
        (records ?? []).filter { $0.deletedAt == nil }
    }

    public var isLive: Bool { deletedAt == nil }
}
```

- [ ] **Step 4: Write `IncomeRecord`**

Create `Sources/TaxData/Models/IncomeRecord.swift`:

```swift
import Foundation
import SwiftData
import TaxKit

public enum IncomeShape: String, Codable, Hashable, Sendable, CaseIterable {
    /// A monthly rate, in force from `effectiveFrom` until something replaces or ends it.
    case recurring
    /// A single amount received on `effectiveFrom` — a bonus, a freelance invoice.
    case oneOff
}

/// One point in a source's history.
///
/// `effectiveFrom` means different things by shape, deliberately: for `recurring` it is the
/// date the rate takes effect, for `oneOff` it is the date the money arrived. One dated
/// field with a documented meaning per shape beats two of which one is always nil.
@Model
public final class IncomeRecord {

    public var id: UUID = UUID()
    public var shapeRaw: String = IncomeShape.recurring.rawValue
    /// A monthly rate for `recurring`; the amount received for `oneOff`.
    public var amountSen: Int = 0
    public var effectiveFrom: Date = Date.distantPast
    public var note: String = ""

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    public var source: IncomeSource?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

extension IncomeRecord {

    public var shape: IncomeShape {
        get { IncomeShape(rawValue: shapeRaw) ?? .recurring }
        set { shapeRaw = newValue.rawValue }
    }

    public var amount: Money {
        get { Money(sen: amountSen) }
        set { amountSen = newValue.sen }
    }

    public var isLive: Bool { deletedAt == nil }
}
```

- [ ] **Step 5: Add both to the schema**

Modify `Sources/TaxData/Schema/SchemaV1.swift` — append to `models`:

```swift
         UserPreferences.self,
         IncomeSource.self,
         IncomeRecord.self]
```

- [ ] **Step 6: Run the tests and commit**

Run: `swift test --filter IncomeModel` — expected PASS.
Run: `swift test` — expected PASS, no regressions (305 + new).

```bash
git add Sources/TaxData Tests/TaxDataTests
git commit -m "feat: add income sources and their dated records"
```

---

### Task 2: `IncomeCalendar` — day-level arithmetic in Kuala Lumpur

**Files:**
- Create: `Sources/TaxData/Income/IncomeCalendar.swift`
- Test: `Tests/TaxDataTests/IncomeCalendarTests.swift`

**Interfaces:**
- Produces:
  - `IncomeCalendar.startOfYear(_ year: Int) -> Date`, `.endOfYear(_:) -> Date`
  - `IncomeCalendar.year(of: Date) -> Int`
  - `IncomeCalendar.startOfDay(_ date: Date) -> Date`
  - `IncomeCalendar.dayBefore(_ date: Date) -> Date`
  - `IncomeCalendar.monthSpans(from: Date, through: Date) -> [MonthSpan]`
  - `struct MonthSpan: Hashable, Sendable { let days: Int; let daysInMonth: Int }`

**This is its own task because the pro-rating in Task 3 is only as correct as this is.**
Spec §5 states the span boundaries to the day precisely because an off-by-one is a real
ringgit error in chargeable income, not a rounding detail. Getting the calendar right in
isolation, with its own tests, is what lets Task 3's tests be about *money* rather than
about dates.

**Fixed calendar, fixed zone, POSIX locale** — the same pattern `AgeCalculator` and
`Normalisation` already use, for the same reason: two devices in different time zones must
derive the same figure for the same household.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxDataTests/IncomeCalendarTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxData

@Suite("Income calendar") struct IncomeCalendarTests {

    /// Builds a Kuala Lumpur date from plain components, so every test below reads as a
    /// calendar date rather than an epoch number.
    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return calendar.date(from: components)!
    }

    @Test("a year's bounds are 1 January to 31 December in Kuala Lumpur")
    func yearBounds() {
        #expect(IncomeCalendar.year(of: IncomeCalendar.startOfYear(2025)) == 2025)
        #expect(IncomeCalendar.year(of: IncomeCalendar.endOfYear(2025)) == 2025)
        // One second before the year starts belongs to the previous year.
        #expect(IncomeCalendar.year(of: IncomeCalendar.startOfYear(2025).addingTimeInterval(-1)) == 2024)
    }

    @Test("a date near midnight is dated by Kuala Lumpur, not UTC")
    func zoneDecidesTheDate() {
        // 2024-12-31 20:00 UTC is 2025-01-01 04:00 in KL. A device abroad must agree with
        // the device at home about which YEAR a payment belongs to.
        let newYearInKL = Date(timeIntervalSince1970: 1_735_675_200)   // 2024-12-31 20:00 UTC
        #expect(IncomeCalendar.year(of: newYearInKL) == 2025)
    }

    @Test("month lengths are real, including February in a leap year")
    func monthLengths() {
        #expect(IncomeCalendar.monthSpans(from: Self.date(2025, 4, 1),
                                          through: Self.date(2025, 4, 30)).first?.daysInMonth == 30)
        #expect(IncomeCalendar.monthSpans(from: Self.date(2025, 2, 1),
                                          through: Self.date(2025, 2, 28)).first?.daysInMonth == 28)
        #expect(IncomeCalendar.monthSpans(from: Self.date(2024, 2, 1),
                                          through: Self.date(2024, 2, 29)).first?.daysInMonth == 29)
    }

    @Test("a whole month is one span of every day in it")
    func wholeMonth() {
        let spans = IncomeCalendar.monthSpans(from: Self.date(2025, 4, 1),
                                              through: Self.date(2025, 4, 30))
        #expect(spans.count == 1)
        #expect(spans[0].days == 30)
        #expect(spans[0].daysInMonth == 30)
    }

    @Test("a partial month counts only its own days, both ends inclusive")
    func partialMonth() {
        // 1–14 April is fourteen days, not thirteen. Both ends are inclusive, which is the
        // off-by-one the whole design turns on.
        let opening = IncomeCalendar.monthSpans(from: Self.date(2025, 4, 1),
                                                through: Self.date(2025, 4, 14))
        #expect(opening == [IncomeCalendar.MonthSpan(days: 14, daysInMonth: 30)])

        let closing = IncomeCalendar.monthSpans(from: Self.date(2025, 4, 15),
                                                through: Self.date(2025, 4, 30))
        #expect(closing == [IncomeCalendar.MonthSpan(days: 16, daysInMonth: 30)])
        #expect(opening[0].days + closing[0].days == 30)
    }

    @Test("a single day is one span of one day")
    func singleDay() {
        let spans = IncomeCalendar.monthSpans(from: Self.date(2025, 4, 15),
                                              through: Self.date(2025, 4, 15))
        #expect(spans == [IncomeCalendar.MonthSpan(days: 1, daysInMonth: 30)])
    }

    @Test("a span across months splits per month with the right lengths")
    func acrossMonths() {
        // 20 Jan through 10 Mar: 12 days of January, all 28 of February, 10 of March.
        let spans = IncomeCalendar.monthSpans(from: Self.date(2025, 1, 20),
                                              through: Self.date(2025, 3, 10))
        #expect(spans == [IncomeCalendar.MonthSpan(days: 12, daysInMonth: 31),
                          IncomeCalendar.MonthSpan(days: 28, daysInMonth: 28),
                          IncomeCalendar.MonthSpan(days: 10, daysInMonth: 31)])
    }

    @Test("an inverted span is empty rather than negative")
    func invertedSpan() {
        // A rate that ends before it starts contributes nothing. Returning a negative day
        // count would subtract money from the year's income.
        #expect(IncomeCalendar.monthSpans(from: Self.date(2025, 4, 15),
                                          through: Self.date(2025, 4, 14)).isEmpty)
    }

    @Test("the day before a date is the previous calendar day")
    func dayBefore() {
        #expect(IncomeCalendar.startOfDay(IncomeCalendar.dayBefore(Self.date(2025, 4, 15)))
                == IncomeCalendar.startOfDay(Self.date(2025, 4, 14)))
        // Across a month boundary, and across a year boundary.
        #expect(IncomeCalendar.startOfDay(IncomeCalendar.dayBefore(Self.date(2025, 3, 1)))
                == IncomeCalendar.startOfDay(Self.date(2025, 2, 28)))
        #expect(IncomeCalendar.startOfDay(IncomeCalendar.dayBefore(Self.date(2025, 1, 1)))
                == IncomeCalendar.startOfDay(Self.date(2024, 12, 31)))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter IncomeCalendar`
Expected: FAIL — "cannot find 'IncomeCalendar' in scope".

- [ ] **Step 3: Write the calendar**

Create `Sources/TaxData/Income/IncomeCalendar.swift`:

```swift
import Foundation

/// Day-level calendar arithmetic for income, in Kuala Lumpur.
///
/// Fixed calendar, fixed zone, POSIX locale — the same discipline `AgeCalculator` and
/// `Normalisation` follow. Two devices in different time zones must derive the same income
/// for the same household, and a payment near midnight must belong to the same year on
/// both.
///
/// Nothing here reads `Date()`. Every function takes the dates it works on.
public enum IncomeCalendar {

    /// Days of a span that fall inside one calendar month, with that month's length.
    /// Pro-rating needs both: fourteen days of April is `14/30`, of February `14/28`.
    public struct MonthSpan: Hashable, Sendable {
        public let days: Int
        public let daysInMonth: Int

        public init(days: Int, daysInMonth: Int) {
            self.days = days
            self.daysInMonth = daysInMonth
        }
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")
            ?? TimeZone(secondsFromGMT: 8 * 3600)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    public static func year(of date: Date) -> Int {
        calendar.component(.year, from: date)
    }

    public static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    public static func dayBefore(_ date: Date) -> Date {
        calendar.date(byAdding: .day, value: -1, to: startOfDay(date)) ?? date
    }

    public static func startOfYear(_ year: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = 1; components.day = 1
        return calendar.date(from: components) ?? .distantPast
    }

    public static func endOfYear(_ year: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = 12; components.day = 31
        return calendar.date(from: components) ?? .distantFuture
    }

    /// Splits an inclusive day range into per-month spans, in calendar order.
    ///
    /// Both ends are inclusive: 1–14 April is fourteen days. That is the off-by-one the
    /// whole derivation turns on, and it is why this returns days rather than a duration.
    public static func monthSpans(from start: Date, through end: Date) -> [MonthSpan] {
        let first = startOfDay(start)
        let last = startOfDay(end)
        guard first <= last else { return [] }   // an inverted span contributes nothing

        var spans: [MonthSpan] = []
        var cursor = first

        while cursor <= last {
            guard let monthRange = calendar.range(of: .day, in: .month, for: cursor),
                  let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: cursor)),
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)
            else { break }

            let monthEnd = dayBefore(nextMonth)
            let spanEnd = min(monthEnd, last)
            let days = (calendar.dateComponents([.day], from: cursor, to: spanEnd).day ?? 0) + 1
            spans.append(MonthSpan(days: days, daysInMonth: monthRange.count))

            cursor = calendar.date(byAdding: .day, value: 1, to: spanEnd) ?? last.addingTimeInterval(86_400)
        }
        return spans
    }
}
```

- [ ] **Step 4: Run the tests and commit**

Run: `swift test --filter IncomeCalendar` — expected PASS, 9 tests.
Run: `swift test` — expected PASS, no regressions.

```bash
git add Sources/TaxData/Income Tests/TaxDataTests/IncomeCalendarTests.swift
git commit -m "feat: add day-level income calendar arithmetic in Kuala Lumpur"
```

---

### Task 3: `IncomeDerivation` — the pure derivation

**Files:**
- Create: `Sources/TaxData/Income/IncomeSnapshots.swift`, `Sources/TaxData/Income/IncomeDerivation.swift`
- Test: `Tests/TaxDataTests/IncomeDerivationTests.swift`

**Interfaces:**
- Consumes: `IncomeCalendar` (Task 2); `IncomeKind`, `IncomeShape` (Task 1); `Money`.
- Produces:
  - `struct IncomeRecordSnapshot: Hashable, Sendable` — `id`, `shape`, `amount`, `effectiveFrom`
  - `struct IncomeSourceSnapshot: Hashable, Sendable` — `id`, `name`, `kind`, `endedOn`, `records`
  - `struct IncomeSourceTotal: Hashable, Sendable, Identifiable` — `sourceID`, `name`, `kind`, `total`
  - `IncomeDerivation.totals(for year: Int, from: [IncomeSourceSnapshot]) -> [IncomeSourceTotal]`
  - `IncomeDerivation.annualGross(for year: Int, from: [IncomeSourceSnapshot]) -> Money`

**This is the heart of the plan, and it is deliberately a pure function over value types
with no SwiftData in sight.** That is the same split that makes `TaxKit`'s evaluator
testable without a simulator, applied one layer up: every boundary case below is a plain
value test with no container, no actor and no clock. `TaxStore` (Task 4) does nothing but
turn models into these snapshots and call this.

**The rules, restated from spec §5 so the implementer does not have to cross-reference:**

- A **one-off** counts when its `effectiveFrom` falls in calendar year `Y`.
- A **recurring** rate runs from its `effectiveFrom` until the earliest of: the next
  recurring record on the same source (**exclusive** — the new rate takes effect on its own
  date, so the old one is paid through the day before), the source's `endedOn`
  (**inclusive** — that is the last day it paid), or 31 December of `Y` (inclusive). It is
  clipped at the start to the later of `effectiveFrom` and 1 January `Y`.
- Partial months pro-rate by days: `rate × days / daysInMonth`, through
  `Money.applying(_:rounding:)` with `.halfUp`, **per month, then summed**. A full month
  yields exactly the rate with no rounding at all.
- Records sort by `effectiveFrom`, ties broken on `id.uuidString` — a total order, so two
  devices cannot disagree about a household's income.
- A rate with no successor and no `endedOn` continues indefinitely, including into later
  years. That is what "my salary is X" means.
- Sources of kind `business` and `rental` **are** counted (spec §8): excluding them would
  understate chargeable income, which overstates what every relief is worth — the harmful
  direction. The warning, not the arithmetic, is how that is handled.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxDataTests/IncomeDerivationTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Income derivation") struct IncomeDerivationTests {

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return calendar.date(from: components)!
    }

    static func rate(_ ringgit: Decimal, from date: Date, id: UUID = UUID()) -> IncomeRecordSnapshot {
        IncomeRecordSnapshot(id: id, shape: .recurring,
                             amount: Money(ringgit: ringgit), effectiveFrom: date)
    }

    static func oneOff(_ ringgit: Decimal, on date: Date, id: UUID = UUID()) -> IncomeRecordSnapshot {
        IncomeRecordSnapshot(id: id, shape: .oneOff,
                             amount: Money(ringgit: ringgit), effectiveFrom: date)
    }

    static func source(_ name: String = "Main job",
                       kind: IncomeKind = .employment,
                       endedOn: Date? = nil,
                       _ records: [IncomeRecordSnapshot]) -> IncomeSourceSnapshot {
        IncomeSourceSnapshot(id: UUID(), name: name, kind: kind,
                             endedOn: endedOn, records: records)
    }

    @Test("a flat salary for a whole year is twelve times the rate, with no rounding")
    func flatYear() {
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1))])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money(ringgit: 96_000))
    }

    @Test("one rate spanning a year boundary is counted correctly in both years")
    func rateCarriesForward() {
        // The whole reason sources are global rather than per-year: a salary set in April
        // 2024 is still in force in January 2025 and must not need re-entering.
        let job = Self.source([Self.rate(8_000, from: Self.date(2024, 4, 1))])
        // 2024 gets April through December — nine months, not twelve.
        #expect(IncomeDerivation.annualGross(for: 2024, from: [job]) == Money(ringgit: 72_000))
        // 2025 gets all twelve, from a record that names no 2025 date at all.
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money(ringgit: 96_000))
        // And the year before it existed gets nothing.
        #expect(IncomeDerivation.annualGross(for: 2023, from: [job]) == Money.zero)
    }

    @Test("a raise on the first of a month has no partial month at all")
    func raiseOnTheFirst() {
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_500, from: Self.date(2025, 4, 1))])
        // Jan–Mar at 8,000, Apr–Dec at 9,500. No pro-rating anywhere.
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job])
                == Money(ringgit: 3 * 8_000 + 9 * 9_500))
    }

    @Test("a mid-month raise blends the month by days")
    func raiseMidMonth() {
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_500, from: Self.date(2025, 4, 15))])
        // April, computed by hand: 1–14 on the old rate is 8,000 × 14/30 = 3,733.33 (rounds
        // DOWN); 15–30 on the new rate is 9,500 × 16/30 = 5,066.67 (rounds UP). They sum to
        // exactly 8,800.00. An implementation that rounds once at the end, or truncates,
        // gets a different number and would pass a whole-months-only test.
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job])
                == Money(ringgit: 24_000) + Money(sen: 880_000) + Money(ringgit: 76_000))
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money(ringgit: 108_800))
    }

    @Test("the old rate is paid through the day before the new one starts")
    func handoverIsExclusive() {
        // One day at 8,000 then the rest of January at 9,500. If the boundary were
        // inclusive on both sides, 2 January would be paid twice.
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_500, from: Self.date(2025, 1, 2))])
        let january = Money(ringgit: 8_000).applying(Decimal(1) / Decimal(31))
            + Money(ringgit: 9_500).applying(Decimal(30) / Decimal(31))
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job])
                == january + Money(ringgit: 11 * 9_500))
    }

    @Test("a job that ends is paid through its last day, inclusive")
    func endedOnIsInclusive() {
        let job = Self.source(endedOn: Self.date(2025, 8, 31),
                              [Self.rate(9_000, from: Self.date(2025, 1, 1))])
        // Eight whole months. Ending on the 31st means that day counted.
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money(ringgit: 72_000))
    }

    @Test("a job that ends on the first counts one day, not zero")
    func endedOnFirstCountsOneDay() {
        let job = Self.source(endedOn: Self.date(2025, 2, 1),
                              [Self.rate(9_000, from: Self.date(2025, 1, 1))])
        let expected = Money(ringgit: 9_000)                                  // all January
            + Money(ringgit: 9_000).applying(Decimal(1) / Decimal(28))        // 1 February
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == expected)
    }

    @Test("one-off amounts count only in the year they were received")
    func oneOffsAreDated() {
        let side = Self.source("Design freelance", kind: .occasional, [
            Self.oneOff(1_800, on: Self.date(2025, 3, 14)),
            Self.oneOff(2_400, on: Self.date(2025, 7, 2)),
            Self.oneOff(950, on: Self.date(2025, 11, 9)),
            Self.oneOff(5_000, on: Self.date(2024, 12, 31))     // last year's, excluded
        ])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [side]) == Money(ringgit: 5_150))
        #expect(IncomeDerivation.annualGross(for: 2024, from: [side]) == Money(ringgit: 5_000))
    }

    @Test("a one-off counts even when no rate is in force")
    func oneOffIndependentOfRates() {
        // A bonus paid after leaving a job is still income received that year.
        let job = Self.source(endedOn: Self.date(2025, 6, 30), [
            Self.rate(9_000, from: Self.date(2025, 1, 1)),
            Self.oneOff(4_000, on: Self.date(2025, 9, 1))
        ])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job])
                == Money(ringgit: 54_000) + Money(ringgit: 4_000))
    }

    @Test("the worked example from the spec")
    func workedExample() {
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_500, from: Self.date(2025, 4, 15))])
        let side = Self.source("Design freelance", kind: .occasional, [
            Self.oneOff(1_800, on: Self.date(2025, 3, 14)),
            Self.oneOff(2_400, on: Self.date(2025, 7, 2)),
            Self.oneOff(950, on: Self.date(2025, 11, 9))
        ])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job, side])
                == Money(ringgit: 113_950))
    }

    @Test("totals are per source, in a stable order, and sum to the gross")
    func totalsPerSource() {
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_500, from: Self.date(2025, 4, 15))])
        let side = Self.source("Design freelance", kind: .occasional, [
            Self.oneOff(1_800, on: Self.date(2025, 3, 14))
        ])
        let totals = IncomeDerivation.totals(for: 2025, from: [job, side])
        #expect(totals.count == 2)
        #expect(totals.map(\.name) == ["Design freelance", "Main job"])   // by name, then id
        #expect(totals.reduce(Money.zero) { $0 + $1.total }
                == IncomeDerivation.annualGross(for: 2025, from: [job, side]))
    }

    @Test("business and rental income is counted, not quietly dropped")
    func outOfScopeKindsStillCount() {
        // Spec §8: excluding them would understate chargeable income, which overstates what
        // every relief is worth — the harmful direction. The warning is how the caveat is
        // delivered; the arithmetic includes them.
        let shop = Self.source("Side business", kind: .business,
                               [Self.oneOff(12_000, on: Self.date(2025, 5, 1))])
        let flat = Self.source("Rental", kind: .rental,
                               [Self.rate(1_500, from: Self.date(2025, 1, 1))])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [shop, flat])
                == Money(ringgit: 12_000) + Money(ringgit: 18_000))
    }

    @Test("records out of order and tied on date resolve deterministically")
    func orderingIsTotal() {
        let earlier = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let later = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let day = Self.date(2025, 6, 1)
        // Two rates on the same day, supplied in both orders. Whatever the rule picks, it
        // must pick the same one every time or two devices disagree about income.
        let one = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_000, from: day, id: earlier),
                               Self.rate(9_500, from: day, id: later)])
        let two = Self.source([Self.rate(9_500, from: day, id: later),
                               Self.rate(9_000, from: day, id: earlier),
                               Self.rate(8_000, from: Self.date(2025, 1, 1))])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [one])
                == IncomeDerivation.annualGross(for: 2025, from: [two]))
    }

    @Test("no income at all is zero, not a crash")
    func emptyIsZero() {
        #expect(IncomeDerivation.annualGross(for: 2025, from: []) == Money.zero)
        #expect(IncomeDerivation.annualGross(for: 2025, from: [Self.source([])]) == Money.zero)
    }

    @Test("a rate starting after the year ends contributes nothing")
    func futureRateIsIgnored() {
        let job = Self.source([Self.rate(9_000, from: Self.date(2026, 3, 1))])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money.zero)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter IncomeDerivation`
Expected: FAIL — "cannot find 'IncomeDerivation' in scope".

- [ ] **Step 3: Write the snapshots**

Create `Sources/TaxData/Income/IncomeSnapshots.swift`:

```swift
import Foundation
import TaxKit

/// One record, as a value. The derivation works on these rather than on `@Model` objects,
/// so every boundary case is testable without a container, an actor or a clock.
public struct IncomeRecordSnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var shape: IncomeShape
    /// A monthly rate for `.recurring`; the amount received for `.oneOff`.
    public var amount: Money
    public var effectiveFrom: Date

    public init(id: UUID = UUID(), shape: IncomeShape = .recurring,
                amount: Money = .zero, effectiveFrom: Date = .distantPast) {
        self.id = id
        self.shape = shape
        self.amount = amount
        self.effectiveFrom = effectiveFrom
    }
}

public struct IncomeSourceSnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: IncomeKind
    /// The last day this source paid, inclusive.
    public var endedOn: Date?
    public var records: [IncomeRecordSnapshot]

    public init(id: UUID = UUID(), name: String = "", kind: IncomeKind = .employment,
                endedOn: Date? = nil, records: [IncomeRecordSnapshot] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endedOn = endedOn
        self.records = records
    }
}

/// What one source contributed to a year — what the Income screen shows per source.
public struct IncomeSourceTotal: Hashable, Sendable, Identifiable {
    public var sourceID: UUID
    public var name: String
    public var kind: IncomeKind
    public var total: Money

    public var id: UUID { sourceID }
}
```

- [ ] **Step 4: Write the derivation**

Create `Sources/TaxData/Income/IncomeDerivation.swift`:

```swift
import Foundation
import TaxKit

/// Turns an income timeline into one year's gross.
///
/// Pure: no SwiftData, no actor, no clock. The year is a parameter, exactly as it is for
/// `AgeCalculator`, so a figure derived today cannot change tomorrow — the same property
/// that makes the engine's golden files meaningful.
public enum IncomeDerivation {

    public static func annualGross(for year: Int, from sources: [IncomeSourceSnapshot]) -> Money {
        totals(for: year, from: sources).reduce(Money.zero) { $0 + $1.total }
    }

    /// Per-source subtotals, ordered by name then id so the screen is stable between
    /// launches and between devices.
    public static func totals(for year: Int,
                              from sources: [IncomeSourceSnapshot]) -> [IncomeSourceTotal] {
        sources
            .map { source in
                IncomeSourceTotal(sourceID: source.id, name: source.name,
                                  kind: source.kind, total: total(for: year, from: source))
            }
            .sorted { left, right in
                if left.name != right.name { return left.name < right.name }
                return left.sourceID.uuidString < right.sourceID.uuidString
            }
    }

    static func total(for year: Int, from source: IncomeSourceSnapshot) -> Money {
        let yearStart = IncomeCalendar.startOfYear(year)
        let yearEnd = IncomeCalendar.endOfYear(year)

        // A total order, so two devices cannot resolve the same records differently.
        let ordered = source.records.sorted { left, right in
            if left.effectiveFrom != right.effectiveFrom {
                return left.effectiveFrom < right.effectiveFrom
            }
            return left.id.uuidString < right.id.uuidString
        }

        let rates = ordered.filter { $0.shape == .recurring }
        var running = Money.zero

        for (index, rate) in rates.enumerated() {
            // The next rate takes effect on its own date, so this one is paid through the
            // day before. `endedOn` is the last day the source paid, so it is inclusive.
            var spanEnd = yearEnd
            if index + 1 < rates.count {
                spanEnd = min(spanEnd, IncomeCalendar.dayBefore(rates[index + 1].effectiveFrom))
            }
            if let endedOn = source.endedOn {
                spanEnd = min(spanEnd, endedOn)
            }
            let spanStart = max(rate.effectiveFrom, yearStart)

            for span in IncomeCalendar.monthSpans(from: spanStart, through: spanEnd) {
                // A full month yields exactly the rate: days == daysInMonth makes the
                // factor 1 and `applying` returns the amount unchanged. Only partial
                // months round, and they round per month rather than once at the end.
                let factor = Decimal(span.days) / Decimal(span.daysInMonth)
                running = running + rate.amount.applying(factor, rounding: .halfUp)
            }
        }

        for oneOff in ordered where oneOff.shape == .oneOff {
            if IncomeCalendar.year(of: oneOff.effectiveFrom) == year {
                running = running + oneOff.amount
            }
        }

        return running
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter IncomeDerivation`
Expected: PASS — 14 tests.

**If `raiseMidMonth` fails**, print the derived figure before changing anything. The
expected 108,800.00 was computed by hand and is in the spec; if the code produces
108,799.99 or 108,800.01 the fault is the rounding *placement* — round per month, not once
over the whole span — not the expectation.

- [ ] **Step 6: Run the whole suite and commit**

Run: `swift test` — expected PASS, no regressions.

```bash
git add Sources/TaxData/Income Tests/TaxDataTests/IncomeDerivationTests.swift
git commit -m "feat: derive a year's gross income from a dated timeline"
```

---

### Task 4: `TaxStore+Income` — the write path and the snapshot projection

**Files:**
- Create: `Sources/TaxData/Store/TaxStore+Income.swift`
- Test: `Tests/TaxDataTests/IncomeStoreTests.swift`

**Interfaces:**
- Consumes: `TaxStore` (its `now` clock and `modelContext`), the models from Task 1, the snapshots from Task 3.
- Produces:
  - `struct IncomeSourceDraft: Hashable, Sendable` — `id`, `name`, `kind`, `deductsEPF: Bool?`, `deductsSOCSO: Bool?`, `endedOn`
  - `struct IncomeRecordDraft: Hashable, Sendable` — `id`, `sourceID`, `shape`, `amount`, `effectiveFrom`, `note`
  - `TaxStore.save(_ draft: IncomeSourceDraft) throws -> UUID`
  - `TaxStore.save(_ draft: IncomeRecordDraft) throws -> UUID`
  - `TaxStore.softDeleteIncomeSource(id:)`, `TaxStore.softDeleteIncomeRecord(id:)`
  - `TaxStore.incomeSourceDrafts() throws -> [IncomeSourceDraft]`
  - `TaxStore.incomeRecordDrafts(forSource:) throws -> [IncomeRecordDraft]`
  - `TaxStore.incomeSnapshots() throws -> [IncomeSourceSnapshot]`
  - `TaxStore.derivedGrossIncome(for year: Int) throws -> Money`

**Everything crossing the actor boundary stays a value type**, as everywhere else in this
package: the store takes drafts and returns drafts or snapshots, never an `IncomeSource`.
That is what keeps "no view touches `ModelContext`" structural rather than a rule someone
has to remember.

**`derivedGrossIncome` is the only new read the projection needs.** It builds snapshots and
hands them to Task 3's pure function; it contains no arithmetic of its own.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxDataTests/IncomeStoreTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Income store") struct IncomeStoreTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return cal.date(from: c)!
    }

    @Test("saving a source and a rate round-trips")
    func saveAndRead() async throws {
        let store = try await StoreFixture.store()
        var job = IncomeSourceDraft(name: "Main job")
        job.deductsEPF = true
        let sourceID = try await store.save(job)

        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.shape = .recurring
        rate.amount = Money(ringgit: 8_000)
        rate.effectiveFrom = Self.date(2025, 1, 1)
        _ = try await store.save(rate)

        let sources = try await store.incomeSourceDrafts()
        #expect(sources.count == 1)
        #expect(sources.first?.name == "Main job")
        #expect(sources.first?.deductsEPF == true)

        let records = try await store.incomeRecordDrafts(forSource: sourceID)
        #expect(records.count == 1)
        #expect(records.first?.amount == Money(ringgit: 8_000))
    }

    @Test("an unasked deduction stays nil through a round trip")
    func unaskedDeductionsSurvive() async throws {
        let store = try await StoreFixture.store()
        _ = try await store.save(IncomeSourceDraft(name: "Design freelance"))
        let read = try await store.incomeSourceDrafts().first
        // Coercing these to false would claim the user confirmed no EPF, which they did not.
        #expect(read?.deductsEPF == nil)
        #expect(read?.deductsSOCSO == nil)
    }

    @Test("every write stamps updatedAt from the injected clock")
    func writesAreStamped() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(IncomeSourceDraft(name: "Main job"))
        #expect(try await store.incomeSourceUpdatedAtForTesting(id) == StoreFixture.epoch)

        let later = StoreFixture.epoch.addingTimeInterval(3_600)
        await store.useClock { later }
        var edited = try #require(try await store.incomeSourceDrafts().first)
        edited.name = "Main job (renamed)"
        _ = try await store.save(edited)
        #expect(try await store.incomeSourceUpdatedAtForTesting(id) == later)
    }

    @Test("editing updates in place rather than inserting a second row")
    func editInPlace() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(IncomeSourceDraft(name: "Main job"))
        var edited = try #require(try await store.incomeSourceDrafts().first)
        edited.kind = .occasional
        _ = try await store.save(edited)

        let all = try await store.incomeSourceDrafts()
        #expect(all.count == 1)
        #expect(all.first?.id == id)
        #expect(all.first?.kind == .occasional)
    }

    @Test("deleting is soft, and a deleted record stops counting")
    func softDeleteRemovesFromDerivation() async throws {
        let store = try await StoreFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Main job"))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 8_000)
        rate.effectiveFrom = Self.date(2025, 1, 1)
        let rateID = try await store.save(rate)

        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 96_000))
        try await store.softDeleteIncomeRecord(id: rateID)
        // A deleted raise that still counted would silently inflate the year's income.
        #expect(try await store.derivedGrossIncome(for: 2025) == Money.zero)
        #expect(try await store.incomeRecordDrafts(forSource: sourceID).isEmpty)
    }

    @Test("deleting a source removes its records from the derivation too")
    func deletingSourceRemovesItsIncome() async throws {
        let store = try await StoreFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Main job"))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 8_000)
        rate.effectiveFrom = Self.date(2025, 1, 1)
        _ = try await store.save(rate)

        try await store.softDeleteIncomeSource(id: sourceID)
        #expect(try await store.derivedGrossIncome(for: 2025) == Money.zero)
        #expect(try await store.incomeSourceDrafts().isEmpty)
    }

    @Test("the store reproduces the spec's worked example end to end")
    func workedExample() async throws {
        let store = try await StoreFixture.store()
        let jobID = try await store.save(IncomeSourceDraft(name: "Main job"))
        for (ringgit, from) in [(Decimal(8_000), Self.date(2025, 1, 1)),
                                (Decimal(9_500), Self.date(2025, 4, 15))] {
            var rate = IncomeRecordDraft(sourceID: jobID)
            rate.amount = Money(ringgit: ringgit)
            rate.effectiveFrom = from
            _ = try await store.save(rate)
        }

        var side = IncomeSourceDraft(name: "Design freelance")
        side.kind = .occasional
        let sideID = try await store.save(side)
        for (ringgit, on) in [(Decimal(1_800), Self.date(2025, 3, 14)),
                              (Decimal(2_400), Self.date(2025, 7, 2)),
                              (Decimal(950), Self.date(2025, 11, 9))] {
            var payment = IncomeRecordDraft(sourceID: sideID)
            payment.shape = .oneOff
            payment.amount = Money(ringgit: ringgit)
            payment.effectiveFrom = on
            _ = try await store.save(payment)
        }

        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 113_950))
    }

    @Test("snapshots are ordered deterministically")
    func snapshotsAreOrdered() async throws {
        let store = try await StoreFixture.store()
        for name in ["Main job", "Design freelance", "Tutoring"] {
            _ = try await store.save(IncomeSourceDraft(name: name))
        }
        let first = try await store.incomeSnapshots().map(\.id)
        let second = try await store.incomeSnapshots().map(\.id)
        #expect(first == second)
        #expect(first == first.sorted { $0.uuidString < $1.uuidString })
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter IncomeStore`
Expected: FAIL — "cannot find 'IncomeSourceDraft' in scope".

- [ ] **Step 3: Write the drafts and the write path**

Create `Sources/TaxData/Store/TaxStore+Income.swift`:

```swift
import Foundation
import SwiftData
import TaxKit

public struct IncomeSourceDraft: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: IncomeKind
    /// `nil` is "not asked yet". Never default this to `false`.
    public var deductsEPF: Bool?
    public var deductsSOCSO: Bool?
    /// The last day this source paid, inclusive.
    public var endedOn: Date?
    public internal(set) var updatedAt: Date

    public init(id: UUID = UUID(), name: String = "", kind: IncomeKind = .employment,
                deductsEPF: Bool? = nil, deductsSOCSO: Bool? = nil, endedOn: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.deductsEPF = deductsEPF
        self.deductsSOCSO = deductsSOCSO
        self.endedOn = endedOn
        self.updatedAt = .distantPast
    }
}

public struct IncomeRecordDraft: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var shape: IncomeShape
    public var amount: Money
    public var effectiveFrom: Date
    public var note: String
    public internal(set) var updatedAt: Date

    public init(id: UUID = UUID(), sourceID: UUID, shape: IncomeShape = .recurring,
                amount: Money = .zero, effectiveFrom: Date = .distantPast, note: String = "") {
        self.id = id
        self.sourceID = sourceID
        self.shape = shape
        self.amount = amount
        self.effectiveFrom = effectiveFrom
        self.note = note
        self.updatedAt = .distantPast
    }
}

extension TaxStore {

    @discardableResult
    public func save(_ draft: IncomeSourceDraft) throws -> UUID {
        let stamp = now()
        let identifier = draft.id
        let existing = try modelContext.fetch(
            FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.id == identifier })
        ).first

        let row = existing ?? IncomeSource(id: identifier)
        if existing == nil { modelContext.insert(row) }

        row.name = draft.name
        row.kind = draft.kind
        row.deductsEPF = draft.deductsEPF
        row.deductsSOCSO = draft.deductsSOCSO
        row.endedOn = draft.endedOn
        row.deletedAt = nil
        row.updatedAt = stamp

        try modelContext.save()
        return identifier
    }

    @discardableResult
    public func save(_ draft: IncomeRecordDraft) throws -> UUID {
        let stamp = now()
        let identifier = draft.id
        let sourceID = draft.sourceID

        let existing = try modelContext.fetch(
            FetchDescriptor<IncomeRecord>(predicate: #Predicate { $0.id == identifier })
        ).first
        let source = try modelContext.fetch(
            FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.id == sourceID })
        ).first

        let row = existing ?? IncomeRecord(id: identifier)
        if existing == nil { modelContext.insert(row) }

        row.shape = draft.shape
        row.amount = draft.amount
        row.effectiveFrom = draft.effectiveFrom
        row.note = draft.note
        row.source = source
        row.deletedAt = nil
        row.updatedAt = stamp

        try modelContext.save()
        return identifier
    }

    /// Idempotent, like every other delete here: deleting an absent or already-deleted id
    /// is a no-op, and an already-deleted row is not re-stamped — a replayed delete must
    /// not outrank a genuine concurrent edit under newest-write-wins.
    public func softDeleteIncomeSource(id: UUID) throws {
        let descriptor = FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.id == id })
        guard let row = try modelContext.fetch(descriptor).first, row.deletedAt == nil else { return }
        let stamp = now()
        row.deletedAt = stamp
        row.updatedAt = stamp
        try modelContext.save()
    }

    public func softDeleteIncomeRecord(id: UUID) throws {
        let descriptor = FetchDescriptor<IncomeRecord>(predicate: #Predicate { $0.id == id })
        guard let row = try modelContext.fetch(descriptor).first, row.deletedAt == nil else { return }
        let stamp = now()
        row.deletedAt = stamp
        row.updatedAt = stamp
        try modelContext.save()
    }

    // MARK: - Reads

    public func incomeSourceDrafts() throws -> [IncomeSourceDraft] {
        try liveSources().map { row in
            var draft = IncomeSourceDraft(id: row.id, name: row.name, kind: row.kind,
                                          deductsEPF: row.deductsEPF,
                                          deductsSOCSO: row.deductsSOCSO,
                                          endedOn: row.endedOn)
            draft.updatedAt = row.updatedAt
            return draft
        }
    }

    public func incomeRecordDrafts(forSource sourceID: UUID) throws -> [IncomeRecordDraft] {
        guard let source = try liveSources().first(where: { $0.id == sourceID }) else { return [] }
        return source.liveRecords
            .sorted { left, right in
                if left.effectiveFrom != right.effectiveFrom {
                    return left.effectiveFrom < right.effectiveFrom
                }
                return left.id.uuidString < right.id.uuidString
            }
            .map { row in
                var draft = IncomeRecordDraft(id: row.id, sourceID: sourceID, shape: row.shape,
                                              amount: row.amount,
                                              effectiveFrom: row.effectiveFrom, note: row.note)
                draft.updatedAt = row.updatedAt
                return draft
            }
    }

    /// The value types the derivation works on. This is the whole bridge between SwiftData
    /// and the pure function — there is no arithmetic here.
    public func incomeSnapshots() throws -> [IncomeSourceSnapshot] {
        try liveSources().map { row in
            IncomeSourceSnapshot(
                id: row.id, name: row.name, kind: row.kind, endedOn: row.endedOn,
                records: row.liveRecords.map {
                    IncomeRecordSnapshot(id: $0.id, shape: $0.shape,
                                         amount: $0.amount, effectiveFrom: $0.effectiveFrom)
                })
        }
    }

    public func derivedGrossIncome(for year: Int) throws -> Money {
        IncomeDerivation.annualGross(for: year, from: try incomeSnapshots())
    }

    public func incomeTotals(for year: Int) throws -> [IncomeSourceTotal] {
        IncomeDerivation.totals(for: year, from: try incomeSnapshots())
    }

    private func liveSources() throws -> [IncomeSource] {
        try modelContext
            .fetch(FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.deletedAt == nil }))
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

// MARK: - Test-only seams

extension TaxStore {
    func incomeSourceUpdatedAtForTesting(_ id: UUID) throws -> Date? {
        try modelContext
            .fetch(FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.id == id }))
            .first?.updatedAt
    }
}
```

- [ ] **Step 4: Run the tests and commit**

Run: `swift test --filter IncomeStore` — expected PASS, 8 tests.
Run: `swift test` — expected PASS, no regressions.

```bash
git add Sources/TaxData/Store Tests/TaxDataTests/IncomeStoreTests.swift
git commit -m "feat: add the income write path and its snapshot projection"
```

---

### Task 5: Switch `TaxYear` over — the override, and removing the dead fields

**Files:**
- Modify: `Sources/TaxData/Models/TaxYear.swift`, `Sources/TaxData/Store/TaxStore.swift`, `Sources/TaxData/Store/TaxStore+Reads.swift`, `Sources/TaxData/Projection/Projection.swift`
- Modify: `Sources/TaxPresentation/OnboardingViewModel.swift` (minimal — keep it compiling; Task 7 redesigns it)
- Modify: existing tests that reference the removed fields
- Test: `Tests/TaxDataTests/ProjectionTests.swift` (append)

**Interfaces:**
- Consumes: `TaxStore.derivedGrossIncome(for:)` from Task 4.
- Produces: `TaxYear.grossIncomeOverrideSen` / `.grossIncomeOverride`; `YearFacts.grossIncomeOverride`; `Projection` using override ?? derived.

**This is the switch-over task and it breaks call sites deliberately.** Tasks 1–4 were
purely additive; this one removes `epfSen`/`socsoSen` and renames the gross field, so
everything referencing them stops compiling until it is updated. That is the point — the
compiler enumerates the call sites so none is missed.

**Why the fields go rather than staying harmlessly.** `epfSen` and `socsoSen` have never
been read by anything (Plan 2's whole-branch review confirmed it). Now that statutory
deductions are a property of a *source* — spec §7, because a second employment deducts them
and occasional 4(f) income does not — a per-year figure has no owner and would be a
tempting wrong answer for whoever wires EPF relief later.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TaxDataTests/ProjectionTests.swift`:

```swift
@Suite("Income projection") struct IncomeProjectionTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return cal.date(from: c)!
    }

    static func seedSalary(_ store: TaxStore, _ ringgit: Decimal) async throws {
        let sourceID = try await store.save(IncomeSourceDraft(name: "Main job"))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: ringgit)
        rate.effectiveFrom = date(2025, 1, 1)
        _ = try await store.save(rate)
    }

    @Test("with no override, the projection uses the derived figure")
    func derivedReachesTheEngine() async throws {
        let store = try await StoreFixture.store()
        try await Self.seedSalary(store, 8_000)
        let projected = try await store.project(year: 2025)
        #expect(projected.snapshot.grossIncome == Money(ringgit: 96_000))
    }

    @Test("an override wins over the derived figure")
    func overrideWins() async throws {
        let store = try await StoreFixture.store()
        try await Self.seedSalary(store, 8_000)
        var facts = try await store.yearFacts(for: 2025)
        // The EA form is authoritative: it includes benefits-in-kind and allowances Relio
        // never saw. When the user says the real total, that is the total.
        facts.grossIncomeOverride = Money(ringgit: 101_500)
        try await store.saveYearFacts(facts, for: 2025)

        let projected = try await store.project(year: 2025)
        #expect(projected.snapshot.grossIncome == Money(ringgit: 101_500))
    }

    @Test("clearing the override returns to the derived figure")
    func clearingOverrideReverts() async throws {
        let store = try await StoreFixture.store()
        try await Self.seedSalary(store, 8_000)
        var facts = try await store.yearFacts(for: 2025)
        facts.grossIncomeOverride = Money(ringgit: 101_500)
        try await store.saveYearFacts(facts, for: 2025)
        facts.grossIncomeOverride = nil
        try await store.saveYearFacts(facts, for: 2025)

        #expect(try await store.project(year: 2025).snapshot.grossIncome == Money(ringgit: 96_000))
    }

    @Test("no income at all still projects nil, not zero")
    func noIncomeIsUnknown() async throws {
        let store = try await StoreFixture.store()
        // nil means "not known", which the engine renders as no tax figures at all. Zero
        // would mean "earned nothing", which is a claim nobody made and which would show a
        // confident RM 0.00 tax bill.
        #expect(try await store.project(year: 2025).snapshot.grossIncome == nil)
    }

    @Test("an override of zero is respected as a real answer")
    func explicitZeroIsRespected() async throws {
        let store = try await StoreFixture.store()
        var facts = try await store.yearFacts(for: 2025)
        facts.grossIncomeOverride = .zero
        try await store.saveYearFacts(facts, for: 2025)
        // A user who genuinely earned nothing this year has said so. That is different
        // from not having told us.
        #expect(try await store.project(year: 2025).snapshot.grossIncome == Money.zero)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter IncomeProjection`
Expected: FAIL — `grossIncomeOverride` does not exist on `YearFacts`.

- [ ] **Step 3: Change `TaxYear`**

In `Sources/TaxData/Models/TaxYear.swift`: delete `epfSen`, `socsoSen` and their computed
`epf` / `socso` accessors; rename `grossIncomeSen` to `grossIncomeOverrideSen` and its
accessor to `grossIncomeOverride`, with this doc comment:

```swift
    /// What the user says the year's gross income really was, overriding the figure
    /// derived from their income timeline.
    ///
    /// `nil` means "derive it". Their EA form is authoritative — it includes
    /// benefits-in-kind, allowances and anything they never logged — so the derived figure
    /// is a default, not the truth. Spec §6.
    public var grossIncomeOverrideSen: Int?
```

- [ ] **Step 4: Change `YearFacts` and the projection**

In `Sources/TaxData/Store/TaxStore.swift`: remove `epf` and `socso` from `YearFacts`, rename
`grossIncome` to `grossIncomeOverride`. Update `saveYearFacts` and `yearFacts(for:)`
accordingly, and remove the two `fillGaps` lines for the deleted fields in
`Sources/TaxData/Dedupe/Reconciliation.swift`.

In `Sources/TaxData/Projection/Projection.swift`, replace the gross assignment:

```swift
        // The user's own figure wins; otherwise derive it from the timeline. `nil` here
        // means "not known", which the engine renders as no tax figures at all — quite
        // different from zero, which would claim they earned nothing.
        snapshot.grossIncome = try facts.grossIncomeOverride ?? nonZeroDerivedGross(for: year)
```

and add, in the same file:

```swift
    /// The derived gross, or `nil` when there is no income timeline at all. Without this
    /// an empty store would report a confident RM 0.00 income and the engine would produce
    /// a full set of tax figures for a household that has told us nothing.
    private func nonZeroDerivedGross(for year: Int) throws -> Money? {
        try incomeSnapshots().isEmpty ? nil : derivedGrossIncome(for: year)
    }
```

- [ ] **Step 5: Fix the call sites the compiler names**

Run `swift build` and work through the errors. Expect: `OnboardingViewModel` (`facts.grossIncome` → `facts.grossIncomeOverride` — keep it compiling only; Task 7 redesigns this step), `TaxStoreTests`, `ProjectionTests`, `PersistedGoldenTests` and `YearContextTests` fixtures.

**In `PersistedGoldenTests`, set `grossIncomeOverride` rather than building a timeline.** That persona exists to prove the engine's output is unchanged; giving it an income timeline would change what the test is testing. The golden file must still pass byte-for-byte.

- [ ] **Step 6: Run everything and commit**

Run: `swift test` — expected PASS. The golden persona must still reproduce `golden-ya2025.json`; if it does not, the projection is wrong, not the fixture.

```bash
git add Sources Tests
git commit -m "feat: derive gross income from the timeline, with the year figure as an override"
```

---

### Task 6: `IncomeViewModel`

**Files:**
- Create: `Sources/TaxPresentation/IncomeViewModel.swift`
- Test: `Tests/TaxPresentationTests/IncomeViewModelTests.swift`

**Interfaces:**
- Consumes: `YearContext`; `TaxStore.incomeSourceDrafts()`, `incomeRecordDrafts(forSource:)`, `incomeTotals(for:)`, `derivedGrossIncome(for:)`, `yearFacts(for:)`, `saveYearFacts(_:for:)`, the two `save` overloads and two soft deletes.
- Produces: `@MainActor @Observable public final class IncomeRecordEditorViewModel`; and `@MainActor @Observable public final class IncomeViewModel` with `sources: [IncomeSourceRow]`, `derivedTotal: Money`, `override: Money?`, `effectiveTotal: Money`, `isOverridden: Bool`, `outOfScopeWarnings: [String]`, `refresh()`, `saveOverride(_:)`, `clearOverride()`, `addSource(_:)`, `addRecord(_:)`, `deleteSource(id:)`, `deleteRecord(id:)`; and `struct IncomeSourceRow: Hashable, Sendable, Identifiable` — `id`, `name`, `kind`, `total`, `records: [IncomeRecordDraft]`, `needsScopeWarning: Bool`.

**No SwiftUI import** — this is what keeps every decision this screen makes covered by
`swift test`.

**`effectiveTotal` is the figure that actually reaches the engine**, so the screen can show
which of the two is in play rather than leaving the user to guess why Home disagrees with
what they typed.

**The editor's state lives here too, not in the view.** `EntryEditorView` already works this
way — it binds to `model.amountText`, a `String` the view model owns, and never parses an
amount itself. Two reasons that pattern is not optional: `Money.formattedForEditing()` is
**internal to `TaxPresentation`**, so an app-target view cannot call it at all; and an
editor that validates in the view puts a decision about the user's money where `swift test`
cannot reach it.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxPresentationTests/IncomeViewModelTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

@Suite("IncomeViewModel") @MainActor struct IncomeViewModelTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return cal.date(from: c)!
    }

    static func model(_ store: TaxStore) async -> IncomeViewModel {
        let context = PresentationFixture.context(store)
        await context.load()
        let model = IncomeViewModel(context: context, store: store)
        await model.refresh()
        return model
    }

    static func seedWorkedExample(_ store: TaxStore) async throws {
        let jobID = try await store.save(IncomeSourceDraft(name: "Main job"))
        for (ringgit, from) in [(Decimal(8_000), date(2025, 1, 1)),
                                (Decimal(9_500), date(2025, 4, 15))] {
            var rate = IncomeRecordDraft(sourceID: jobID)
            rate.amount = Money(ringgit: ringgit); rate.effectiveFrom = from
            _ = try await store.save(rate)
        }
        var side = IncomeSourceDraft(name: "Design freelance"); side.kind = .occasional
        let sideID = try await store.save(side)
        for (ringgit, on) in [(Decimal(1_800), date(2025, 3, 14)),
                              (Decimal(2_400), date(2025, 7, 2)),
                              (Decimal(950), date(2025, 11, 9))] {
            var payment = IncomeRecordDraft(sourceID: sideID)
            payment.shape = .oneOff; payment.amount = Money(ringgit: ringgit)
            payment.effectiveFrom = on
            _ = try await store.save(payment)
        }
    }

    @Test("sources carry their own subtotals and sum to the derived total")
    func subtotals() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)

        #expect(model.sources.count == 2)
        #expect(model.derivedTotal == Money(ringgit: 113_950))
        #expect(model.sources.reduce(Money.zero) { $0 + $1.total } == model.derivedTotal)
        #expect(model.sources.first { $0.name == "Design freelance" }?.total
                == Money(ringgit: 5_150))
    }

    @Test("without an override the effective total is the derived one")
    func effectiveIsDerived() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)
        #expect(!model.isOverridden)
        #expect(model.effectiveTotal == model.derivedTotal)
    }

    @Test("an override replaces the effective total and is visible as such")
    func overrideIsVisible() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)

        await model.saveOverride(Money(ringgit: 120_000))
        #expect(model.isOverridden)
        #expect(model.effectiveTotal == Money(ringgit: 120_000))
        // The derived figure stays visible so the user can see the two disagree and decide
        // which is right — that is the whole point of showing both.
        #expect(model.derivedTotal == Money(ringgit: 113_950))

        await model.clearOverride()
        #expect(!model.isOverridden)
        #expect(model.effectiveTotal == Money(ringgit: 113_950))
    }

    @Test("saving an override refreshes the shared evaluation")
    func overrideRefreshesTheContext() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)
        await model.saveOverride(Money(ringgit: 120_000))
        // Otherwise Home keeps showing tax figures computed from the old income.
        #expect(model.context.result?.chargeableIncome != nil)
        #expect(model.context.result?.estimatedTax != nil)
    }

    @Test("business and rental sources are flagged, employment and occasional are not")
    func scopeWarnings() async throws {
        let store = try await PresentationFixture.store()
        var shop = IncomeSourceDraft(name: "Side business"); shop.kind = .business
        _ = try await store.save(shop)
        var job = IncomeSourceDraft(name: "Main job")
        _ = try await store.save(job)
        var gig = IncomeSourceDraft(name: "Tutoring"); gig.kind = .occasional
        _ = try await store.save(gig)
        let model = await Self.model(store)

        // Occasional work is ITA 1967 §4(f) and belongs on Form BE — it must NOT be
        // flagged, or the warning becomes noise the user learns to ignore.
        #expect(model.sources.first { $0.name == "Side business" }?.needsScopeWarning == true)
        #expect(model.sources.first { $0.name == "Main job" }?.needsScopeWarning == false)
        #expect(model.sources.first { $0.name == "Tutoring" }?.needsScopeWarning == false)
        #expect(model.outOfScopeWarnings.count == 1)
    }

    @Test("adding a rate updates the total without a manual reload")
    func addingARateRecomputes() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store)
        #expect(model.derivedTotal == Money.zero)

        let sourceID = await model.addSource(IncomeSourceDraft(name: "Main job"))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 8_000)
        rate.effectiveFrom = Self.date(2025, 1, 1)
        await model.addRecord(rate)

        #expect(model.derivedTotal == Money(ringgit: 96_000))
    }

    @Test("deleting a record lowers the total")
    func deletingRecomputes() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)
        let side = try #require(model.sources.first { $0.name == "Design freelance" })
        let payment = try #require(side.records.first)

        await model.deleteRecord(id: payment.id)
        #expect(model.derivedTotal == Money(ringgit: 113_950) - Money(ringgit: 1_800))
    }

    @Test("a year with no income reports zero without crashing")
    func emptyYear() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store)
        #expect(model.sources.isEmpty)
        #expect(model.derivedTotal == Money.zero)
        #expect(!model.isOverridden)
    }
}

@Suite("IncomeRecordEditorViewModel") @MainActor struct IncomeRecordEditorViewModelTests {

    @Test("a new source needs a name")
    func sourceNeedsAName() {
        let editor = IncomeRecordEditorViewModel(mode: .addSource)
        #expect(!editor.canSave)
        editor.name = "   "
        #expect(!editor.canSave, "whitespace is not a name")
        editor.name = "Main job"
        #expect(editor.canSave)
    }

    @Test("a record needs an amount above zero")
    func recordNeedsAnAmount() {
        let editor = IncomeRecordEditorViewModel(mode: .addRecord(sourceID: UUID()))
        #expect(!editor.canSave)
        editor.amountText = "abc"
        #expect(!editor.canSave)
        #expect(editor.validationError != nil)
        editor.amountText = "0"
        #expect(!editor.canSave)
        editor.amountText = "8000"
        #expect(editor.canSave)
        #expect(editor.validationError == nil)
    }

    @Test("editing loads the record as plain digits, not display format")
    func editingLoadsPlainDigits() {
        var record = IncomeRecordDraft(sourceID: UUID())
        record.amount = Money(sen: 950_000)
        record.shape = .oneOff
        let editor = IncomeRecordEditorViewModel(mode: .edit(record))
        // "RM 9,500.00" in a text field means deleting the prefix before you can type.
        #expect(editor.amountText == "9500.00")
        #expect(editor.shape == .oneOff)
    }

    @Test("editing produces a draft with the same id, so it updates in place")
    func editKeepsItsIdentity() {
        var record = IncomeRecordDraft(sourceID: UUID())
        record.amount = Money(ringgit: 8_000)
        let editor = IncomeRecordEditorViewModel(mode: .edit(record))
        editor.amountText = "9500"
        let produced = try? #require(editor.recordDraft())
        #expect(produced??.id == record.id)
        #expect(produced??.amount == Money(ringgit: 9_500))
    }

    @Test("the kind footnote tells the truth about each kind")
    func kindFootnotes() {
        // Occasional work is Form BE and Relio handles it — saying otherwise would make
        // the caveat noise. Business and rental must say the estimate will be too high.
        #expect(!IncomeRecordEditorViewModel.footnote(for: .occasional).contains("Form B "))
        #expect(IncomeRecordEditorViewModel.footnote(for: .business).contains("Form B"))
        #expect(IncomeRecordEditorViewModel.footnote(for: .rental).contains("deductible"))
        for kind in IncomeKind.allCases {
            #expect(!IncomeRecordEditorViewModel.footnote(for: kind).isEmpty)
            #expect(!IncomeRecordEditorViewModel.label(for: kind).isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter IncomeViewModel`
Expected: FAIL — "cannot find 'IncomeViewModel' in scope".

- [ ] **Step 3: Write the view model**

Create `Sources/TaxPresentation/IncomeViewModel.swift`:

```swift
import Foundation
import Observation
import TaxKit
import TaxData

public struct IncomeSourceRow: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: IncomeKind
    public var total: Money
    public var records: [IncomeRecordDraft]
    /// True for income Relio does not model correctly — see `IncomeViewModel`.
    public var needsScopeWarning: Bool
}

/// The Income screen's state.
///
/// Shows the derivation, not just its result: a user who cannot see why Relio thinks they
/// earned what it says cannot tell whether it is right, and this figure drives every tax
/// number in the app. Spec §10.
@MainActor
@Observable
public final class IncomeViewModel {

    public let context: YearContext
    public private(set) var sources: [IncomeSourceRow] = []
    public private(set) var derivedTotal: Money = .zero
    public private(set) var override: Money?
    public private(set) var outOfScopeWarnings: [String] = []

    private let store: TaxStore

    public init(context: YearContext, store: TaxStore) {
        self.context = context
        self.store = store
    }

    public var isOverridden: Bool { override != nil }

    /// The figure that actually reaches the engine.
    public var effectiveTotal: Money { override ?? derivedTotal }

    public func refresh() async {
        let year = context.year
        let totals = (try? await store.incomeTotals(for: year)) ?? []
        let drafts = (try? await store.incomeSourceDrafts()) ?? []

        var rows: [IncomeSourceRow] = []
        for total in totals {
            guard let draft = drafts.first(where: { $0.id == total.sourceID }) else { continue }
            let records = (try? await store.incomeRecordDrafts(forSource: total.sourceID)) ?? []
            rows.append(IncomeSourceRow(id: total.sourceID, name: total.name, kind: total.kind,
                                        total: total.total, records: records,
                                        needsScopeWarning: Self.isOutOfScope(draft.kind)))
        }
        sources = rows
        derivedTotal = totals.reduce(Money.zero) { $0 + $1.total }
        override = (try? await store.yearFacts(for: year))?.grossIncomeOverride
        outOfScopeWarnings = rows.filter(\.needsScopeWarning).map(Self.warning(for:))
    }

    /// Business and rental income only. Occasional work is ITA 1967 §4(f) and is declared
    /// on Form BE, so flagging it would make the warning noise the user learns to ignore.
    static func isOutOfScope(_ kind: IncomeKind) -> Bool {
        kind == .business || kind == .rental
    }

    static func warning(for row: IncomeSourceRow) -> String {
        switch row.kind {
        case .business:
            return "\(row.name) looks like business income. Relio estimates Form BE figures; business income belongs on Form B, where expenses are deductible."
        case .rental:
            return "\(row.name) is rental income. Relio counts it in full, but rental expenses are deductible, so your real chargeable income is lower."
        default:
            return ""
        }
    }

    // MARK: - Writes

    public func saveOverride(_ amount: Money?) async {
        guard var facts = try? await store.yearFacts(for: context.year) else { return }
        facts.grossIncomeOverride = amount
        try? await store.saveYearFacts(facts, for: context.year)
        await reloadEverything()
    }

    public func clearOverride() async {
        await saveOverride(nil)
    }

    @discardableResult
    public func addSource(_ draft: IncomeSourceDraft) async -> UUID {
        let id = (try? await store.save(draft)) ?? draft.id
        await reloadEverything()
        return id
    }

    public func addRecord(_ draft: IncomeRecordDraft) async {
        _ = try? await store.save(draft)
        await reloadEverything()
    }

    public func deleteSource(id: UUID) async {
        try? await store.softDeleteIncomeSource(id: id)
        await reloadEverything()
    }

    public func deleteRecord(id: UUID) async {
        try? await store.softDeleteIncomeRecord(id: id)
        await reloadEverything()
    }

    /// Income changes chargeable income, so every tax figure in the app moves with it.
    /// Reloading the shared evaluation is not optional here.
    private func reloadEverything() async {
        await context.reload()
        await refresh()
    }
}
```

- [ ] **Step 4: Write the editor's view model**

Create `Sources/TaxPresentation/IncomeRecordEditorViewModel.swift`:

```swift
import Foundation
import Observation
import TaxKit
import TaxData

/// The state behind the income editor sheet.
///
/// It lives here rather than in the view for two reasons: `Money.formattedForEditing()` is
/// internal to this module, so an app-target view cannot call it; and an editor that
/// validates in the view puts a decision about the user's money where `swift test` cannot
/// reach it.
@MainActor
@Observable
public final class IncomeRecordEditorViewModel {

    public enum Mode: Hashable, Sendable {
        case addSource
        case addRecord(sourceID: UUID)
        case edit(IncomeRecordDraft)
    }

    public let mode: Mode
    public var name: String = ""
    public var kind: IncomeKind = .employment
    public var shape: IncomeShape = .recurring
    public var amountText: String = ""
    public var effectiveFrom: Date

    public init(mode: Mode, today: Date = Date()) {
        self.mode = mode
        self.effectiveFrom = today
        if case .edit(let record) = mode {
            shape = record.shape
            amountText = record.amount.formattedForEditing()
            effectiveFrom = record.effectiveFrom
        }
    }

    public var isSourceMode: Bool {
        if case .addSource = mode { return true }
        return false
    }

    public var validationError: String? {
        if isSourceMode {
            return name.trimmingCharacters(in: .whitespaces).isEmpty ? "Give this a name." : nil
        }
        guard let amount = MoneyParsing.money(from: amountText) else {
            return amountText.isEmpty ? "Enter an amount." : "That is not an amount."
        }
        return amount > .zero ? nil : "The amount must be more than RM 0.00."
    }

    public var canSave: Bool { validationError == nil }

    public func sourceDraft() -> IncomeSourceDraft? {
        guard isSourceMode, canSave else { return nil }
        var draft = IncomeSourceDraft(name: name.trimmingCharacters(in: .whitespaces))
        draft.kind = kind
        return draft
    }

    /// For `.edit`, keeps the record's id so the store updates in place rather than
    /// inserting a second row.
    public func recordDraft() -> IncomeRecordDraft? {
        guard !isSourceMode, canSave,
              let amount = MoneyParsing.money(from: amountText) else { return nil }

        var draft: IncomeRecordDraft
        switch mode {
        case .addRecord(let sourceID):
            draft = IncomeRecordDraft(sourceID: sourceID)
        case .edit(let record):
            draft = record
        case .addSource:
            return nil
        }
        draft.shape = shape
        draft.amount = amount
        draft.effectiveFrom = effectiveFrom
        return draft
    }

    public static func label(for kind: IncomeKind) -> String {
        switch kind {
        case .employment: "A job"
        case .occasional: "Part-time or occasional work"
        case .business:   "A registered business"
        case .rental:     "Rental"
        case .other:      "Something else"
        }
    }

    /// Says what Relio can and cannot do with each kind at the moment the user picks it,
    /// which is earlier and more useful than a warning after the fact.
    public static func footnote(for kind: IncomeKind) -> String {
        switch kind {
        case .employment:
            "Counted in full. Relio handles this."
        case .occasional:
            "Occasional work is declared on Form BE under other gains and profits. Relio handles this."
        case .business:
            "A registered business is filed on Form B, where expenses are deductible. Relio counts this income in full, so its estimate will be higher than what you file."
        case .rental:
            "Rental expenses are deductible. Relio counts the full amount, so its estimate will be higher than what you file."
        case .other:
            "Counted in full. Check how this income is treated before relying on the estimate."
        }
    }
}
```

`Money.formattedForEditing()` already exists in this module, declared on `EntryEditorViewModel`'s
extension. Leave it internal — the point is that only this layer formats.

- [ ] **Step 5: Run the tests and commit**

Run: `swift test --filter "IncomeViewModel|IncomeRecordEditorViewModel"` — expected PASS, 13 tests.
Run: `swift test` — expected PASS.

```bash
git add Sources/TaxPresentation Tests/TaxPresentationTests
git commit -m "feat: add the income view model with a visible derivation"
```

---

### Task 7: The Income screen, and onboarding asking what it can know

**Files:**
- Create: `App/TaxTracker/Income/IncomeView.swift`, `App/TaxTracker/Income/IncomeRecordEditor.swift`
- Modify: `App/TaxTracker/RootView.swift`, `App/TaxTracker/Support/Routes.swift`, `App/TaxTracker/Onboarding/OnboardingView.swift`, `Sources/TaxPresentation/OnboardingViewModel.swift`
- Test: `Tests/TaxPresentationTests/OnboardingViewModelTests.swift` (append)

**Interfaces:**
- Consumes: `IncomeViewModel` (Task 6), the drafts from Task 4.
- Produces: `IncomeView`, `IncomeRecordEditor`, `IncomeRoute`; `OnboardingViewModel.monthlySalary` / `.salaryStartedOn` replacing `.facts.grossIncomeOverride`.

**Verification.** `xcodebuild` cannot enumerate simulator destinations on this machine
(Xcode's first-launch install needs interactive admin auth). Use `./Scripts/typecheck-app.sh`
and `swift test`. `./Scripts/run-app.sh` builds, installs and launches the app by hand and
**does** work — use it to see the screen, and read the screenshot rather than assuming.

**Onboarding stops asking for a year total.** It asks the two things a user actually knows
on the day they install: **what they earn a month, and since when.** That creates one source
with one recurring record. It stays fully skippable — parent spec §1 requires a receipt to
be loggable in 30 seconds without entering income at all.

**The screen shows the derivation, not just its result.** Each source lists its records with
dates, its subtotal, and the year's derived total; the override sits beneath, showing which
figure is actually in play. Spec §10.

- [ ] **Step 1: Change the onboarding view model**

Replace the income handling in `Sources/TaxPresentation/OnboardingViewModel.swift`:

```swift
    /// What the user earns a month, and when that started. Onboarding asks for these two
    /// because they are what a person knows on the day they install the app — an annual
    /// total is arithmetic they would have to do themselves, which is the problem the
    /// income timeline exists to remove.
    public var monthlySalary: Money?
    public var salaryStartedOn: Date?
```

and in `complete()`, replace the income branch:

```swift
        if incomeEnabled, let monthlySalary, monthlySalary > .zero {
            let sourceID = (try? await store.save(IncomeSourceDraft(name: "Main job"))) ?? UUID()
            var rate = IncomeRecordDraft(sourceID: sourceID)
            rate.shape = .recurring
            rate.amount = monthlySalary
            // Default to the start of the year being onboarded rather than today: a salary
            // the user has had all year should count for the whole year.
            rate.effectiveFrom = salaryStartedOn ?? IncomeCalendar.startOfYear(year)
            try? await store.save(rate)
        }
```

Note `facts` no longer carries income at all — `saveYearFacts` keeps writing the household
facts as before.

- [ ] **Step 2: Write the failing onboarding tests**

Append to `Tests/TaxPresentationTests/OnboardingViewModelTests.swift`:

```swift
    @Test("finishing with a salary creates a source and a rate")
    func salaryBecomesASource() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.incomeEnabled = true
        model.monthlySalary = Money(ringgit: 8_000)
        await model.finish()

        let sources = try await store.incomeSourceDrafts()
        #expect(sources.count == 1)
        #expect(sources.first?.name == "Main job")
        // No start date given, so it runs from the start of the year being onboarded —
        // a salary the user has had all year counts for the whole year.
        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 96_000))
    }

    @Test("a salary start date part-way through the year is honoured")
    func salaryStartDateIsUsed() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.incomeEnabled = true
        model.monthlySalary = Money(ringgit: 9_000)
        var components = DateComponents()
        components.year = 2025; components.month = 7; components.day = 1; components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        model.salaryStartedOn = calendar.date(from: components)!
        await model.finish()

        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 54_000))
    }

    @Test("income left off writes no source even if a salary was typed")
    func incomeToggleGatesTheSource() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.monthlySalary = Money(ringgit: 8_000)
        model.incomeEnabled = false
        await model.finish()
        // Otherwise turning the module off later leaves a stale salary quietly driving
        // every tax figure in the app.
        #expect(try await store.incomeSourceDrafts().isEmpty)
        #expect(try await store.derivedGrossIncome(for: 2025) == Money.zero)
    }

    @Test("skipping writes no income at all")
    func skipWritesNothing() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.incomeEnabled = true
        model.monthlySalary = Money(ringgit: 8_000)
        await model.skip()
        #expect(try await store.incomeSourceDrafts().isEmpty)
    }
```

Run: `swift test --filter Onboarding` — observe the failure, then make it pass.

- [ ] **Step 3: Write the Income screen**

Create `App/TaxTracker/Income/IncomeView.swift`. Structure — sources with their records and
subtotals, then the derived total, then the override:

```swift
import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

struct IncomeView: View {

    @Bindable var model: IncomeViewModel
    @State private var editing: IncomeRecordEditorViewModel?
    @State private var overrideText = ""

    var body: some View {
        List {
            ForEach(model.sources) { source in
                Section {
                    ForEach(source.records) { record in
                        Button {
                            editing = IncomeRecordEditorViewModel(mode: .edit(record))
                        } label: { recordRow(record) }
                            .buttonStyle(.plain)
                    }
                    Button("Add a change") {
                        editing = IncomeRecordEditorViewModel(mode: .addRecord(sourceID: source.id))
                    }
                    .font(.subheadline)
                } header: {
                    HStack {
                        Text(source.name)
                        Spacer()
                        MoneyText(amount: source.total, font: .subheadline, weight: .semibold)
                    }
                } footer: {
                    if source.needsScopeWarning,
                       let warning = model.outOfScopeWarnings.first(where: { $0.contains(source.name) }) {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Gross income for YA \(String(model.context.year))") {
                LabeledContent("From your records") {
                    MoneyText(amount: model.derivedTotal, weight: .medium)
                }
                LabeledContent("Your own figure") {
                    TextField("Optional", text: $overrideText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .onSubmit { Task { await model.saveOverride(MoneyParsing.money(from: overrideText)) } }
                }
                if model.isOverridden {
                    Button("Use my records instead") {
                        overrideText = ""
                        Task { await model.clearOverride() }
                    }
                }
            } footer: {
                Text(model.isOverridden
                     ? "Relio is using your own figure. Your EA form is the one that counts."
                     : "Relio adds up your records. If your EA form says something different, enter it above.")
            }
        }
        .navigationTitle("Income")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = IncomeRecordEditorViewModel(mode: .addSource)
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add an income source")
            }
        }
        .sheet(item: $editing) { editor in
            IncomeRecordEditor(editor: editor, model: model)
        }
        .task { await model.refresh() }
        .overlay {
            if model.sources.isEmpty {
                ContentUnavailableView("No income recorded",
                                       systemImage: "banknote",
                                       description: Text("Add your salary and Relio will work out the year's total, including any raises."))
            }
        }
    }

    private func recordRow(_ record: IncomeRecordDraft) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.effectiveFrom, format: .dateTime.day().month(.abbreviated).year())
                Text(record.shape == .recurring ? "a month" : "one-off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(amount: record.amount, font: .subheadline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(record))
    }

    private func accessibilityLabel(_ record: IncomeRecordDraft) -> String {
        let date = record.effectiveFrom.formatted(.dateTime.day().month(.wide).year())
        return record.shape == .recurring
            ? "From \(date), \(record.amount.formatted()) a month"
            : "\(date), \(record.amount.formatted()) received"
    }
}
```

Create `App/TaxTracker/Income/IncomeRecordEditor.swift` — bindings only; every decision
below lives in `IncomeRecordEditorViewModel`:

```swift
import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

struct IncomeRecordEditor: View {

    @Bindable var editor: IncomeRecordEditorViewModel
    let model: IncomeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if editor.isSourceMode {
                    Section {
                        TextField("Name", text: $editor.name)
                        Picker("Kind", selection: $editor.kind) {
                            ForEach(IncomeKind.allCases, id: \.self) { kind in
                                Text(IncomeRecordEditorViewModel.label(for: kind)).tag(kind)
                            }
                        }
                    } footer: {
                        Text(IncomeRecordEditorViewModel.footnote(for: editor.kind))
                    }
                } else {
                    Section {
                        Picker("This is", selection: $editor.shape) {
                            Text("A monthly rate").tag(IncomeShape.recurring)
                            Text("A one-off payment").tag(IncomeShape.oneOff)
                        }
                        LabeledContent(editor.shape == .recurring ? "Amount a month" : "Amount") {
                            TextField("0.00", text: $editor.amountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                        DatePicker(editor.shape == .recurring ? "From" : "Received on",
                                   selection: $editor.effectiveFrom, displayedComponents: .date)
                    } footer: {
                        Text(editor.shape == .recurring
                             ? "Relio pays this rate from that date until you change it. A change part-way through a month is split by days."
                             : "Counted in the year it was received.")
                    }

                    if let error = editor.validationError, !editor.amountText.isEmpty {
                        Section { Text(error).foregroundStyle(.orange).font(.footnote) }
                    }
                }
            }
            .navigationTitle(editor.isSourceMode ? "New source" : "Change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!editor.canSave)
                }
            }
        }
    }

    private func save() async {
        if let source = editor.sourceDraft() {
            await model.addSource(source)
        } else if let record = editor.recordDraft() {
            // `.edit` keeps the record's id, so this updates in place.
            await model.addRecord(record)
        }
        dismiss()
    }
}
```

`IncomeView` holds the editor in `@State` and presents it with `.sheet(item:)` keyed on the
mode, matching how `RootView` presents the entry editor — **never constructed inside a
presentation closure**, which is the defect the view-layer review found in Plan 2. Make
`IncomeRecordEditorViewModel` `Identifiable` with `nonisolated var id: ObjectIdentifier`,
as `EntryEditorViewModel` already is.

- [ ] **Step 4: Wire navigation and the onboarding screen**

Add `struct IncomeRoute: Hashable {}` to `App/TaxTracker/Support/Routes.swift`. In
`RootView`, add an `Income` item to the year menu and a destination:

```swift
                    .navigationDestination(for: IncomeRoute.self) { _ in
                        IncomeView(model: income)
                    }
```

holding `income` in `@State` alongside the other view models — **not constructed inside the
destination closure**, which is the defect the view-layer review found and fixed.

In `OnboardingView`'s `.income` case, replace the annual-income field with a monthly salary
field and a "since" date, bound to `model.monthlySalary` and `model.salaryStartedOn`.

- [ ] **Step 5: Verify by rendering, not by reasoning**

Run: `swift test` — expected PASS.
Run: `./Scripts/typecheck-app.sh` — expected "Type-check succeeded".
Run: `./Scripts/run-app.sh /tmp/income-screen.png`, then **read the screenshot**. Confirm the
onboarding income step asks for a monthly figure and a date.

Then check the Income screen at the largest Dynamic Type size, since it is dense with
figures and dates:

```bash
xcrun simctl ui "Relio Test Phone" content_size accessibility-extra-extra-extra-large
xcrun simctl io "Relio Test Phone" screenshot /tmp/income-ax5.png
xcrun simctl ui "Relio Test Phone" content_size large
```

Read it. A truncated amount is a defect — the onboarding screen shipped exactly that until
a real render caught it.

- [ ] **Step 6: Commit**

```bash
git add App Sources/TaxPresentation Tests
git commit -m "feat: add the Income screen and ask onboarding for a monthly salary"
```

---

### Task 8: Verification pass and documentation

**Files:**
- Modify: `README.md`
- Test: `Tests/TaxDataTests/IncomeDerivationTests.swift` (append one regression test)

**This task exists to prove the plan did not break what it was built on.** The engine was
untouched by design; this is where that claim is tested rather than asserted.

- [ ] **Step 1: Prove the engine is genuinely untouched**

Run: `git diff <plan-base>..HEAD -- Sources/TaxKit` — expected: empty output.

If it is not empty, something modified the engine and the golden files no longer mean what
they did. Stop and report it.

- [ ] **Step 2: Prove the golden persona is unchanged**

Run: `swift test --filter "GoldenFile|PersistedGolden"` — expected PASS.

`PersistedGoldenTests` sets `grossIncomeOverride` rather than building a timeline, so it
still asserts exactly what it did before: that persistence feeds the engine correctly. The
income timeline is a new input path, not a change to that one.

- [ ] **Step 3: Add the no-Double regression test**

Append to `Tests/TaxDataTests/IncomeDerivationTests.swift`:

```swift
    @Test("the derivation path contains no Double")
    func noDoubleInDerivation() throws {
        // This is a calculation path feeding chargeable income. `Double` here would
        // reintroduce exactly the representation error `Money` exists to prevent, at the
        // point where a user's salary becomes a tax figure.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let income = root.appending(path: "Sources/TaxData/Income")
        let files = try FileManager.default
            .contentsOfDirectory(at: income, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                guard text.contains("Double") else { continue }
                #expect(text.contains("//"),
                        "\(file.lastPathComponent):\(number + 1) uses Double on the derivation path")
            }
        }
    }
```

- [ ] **Step 4: Run every gate**

```bash
swift test
./Scripts/typecheck-app.sh
grep -rn "import SwiftData\|import SwiftUI" Sources/TaxKit    # expect nothing
grep -rn "import SwiftUI" Sources/TaxData Sources/TaxPresentation   # expect nothing
grep -rn "epfSen\|socsoSen\|grossIncomeSen" Sources Tests App       # expect nothing
```

The last one confirms the switch-over in Task 5 left no stragglers.

- [ ] **Step 5: Update the README**

In the status table, note that income is tracked as a dated timeline rather than one figure
per year. Add to the feature list, in the README's existing plain voice:

> **Income that changes.** A raise in April or a second job in September is recorded once,
> as it happens. Relio derives the year's gross by pro-rating each month by days, so a
> mid-month raise blends correctly — and shows its working, because that figure drives
> every tax number in the app. Your own figure from your EA form always wins.

Do not claim EPF or SOCSO relief is derived from salary; it is not, and §3 of the spec says
why.

- [ ] **Step 6: Commit**

```bash
git add README.md Tests
git commit -m "test: pin the engine and golden persona as unchanged by the income timeline"
```

---

## Definition of done

- [ ] `swift test` passes; the suite has grown by roughly 45 tests and none was removed.
- [ ] `./Scripts/typecheck-app.sh` passes.
- [ ] `git diff <plan-base>..HEAD -- Sources/TaxKit` is empty. **The engine is untouched.**
- [ ] `golden-ya2025.json` is unchanged and both golden suites pass.
- [ ] `grep -rn "epfSen\|socsoSen\|grossIncomeSen" Sources Tests App` returns nothing.
- [ ] No `Double` under `Sources/TaxData/Income`.
- [ ] `SchemaInvariantTests` passes over all nine models.
- [ ] The spec's worked example — RM 113,950, with April blending to exactly RM 8,800.00 —
      is asserted at three levels: the pure derivation, the store, and the view model.
- [ ] The app launches via `./Scripts/run-app.sh` and the Income screen has been read at
      default size and at AX5.

## Carried forward

1. **Deriving EPF and SOCSO relief from salary.** Spec §3. The data is now in place —
   `deductsEPF` and `deductsSOCSO` per source — so the work can know which sources
   contributed instead of assuming every ringgit was subject to an 11% deduction. Needs the
   statutory rate by age band and the interaction with the RM 4,000 cap.
2. **Editing a past year's income** offers no warning that the user may already have filed
   on the old figure. Spec §12.
3. **`endedOn` is never inferred** when a new employment source starts. Two concurrent jobs
   are real, so this stays explicit.
4. Everything already carried from Plan 2, including that `reconcile()` and
   `recomputeAllDedupeKeys()` still have no production caller.
5. **No restore path for income.** `TaxStore` has `softDeleteIncomeSource`/
   `softDeleteIncomeRecord` but no restore, so the Income screen's deletions are
   unrecoverable from the UI — unlike relief entries, which have `undoDelete()` and an undo
   toast. The source delete is confirmed by an alert; per-record swipe-delete is not.
6. **Records that do not contribute to the viewed year are not marked.** They render
   identically to contributing ones beneath a year-scoped subtotal. Marking them by date
   would be wrong — a recurring rate dated 1 April 2024 with no successor legitimately
   contributes to YA2025 — so doing this correctly needs per-record contribution data from
   `IncomeDerivation`. The data is closer now: `IncomeYearSummary` carries the same
   known/unknown answer the projection uses up to the view model, so what is left is
   exposing `IncomeDerivation.contributions` per record rather than walking the timeline a
   second time in the presentation layer.
7. **A user in a time zone east of UTC+8** who picks a date stores an instant that can
   still be the previous day in Kuala Lumpur, so it reads back a day earlier. This is a
   pre-existing, codebase-wide property affecting `Dependent.dateOfBirth` and relief-entry
   dates identically; this plan neither introduces nor worsens it.
8. ~~**No dedupe or reconciliation for `IncomeSource`.**~~ **Resolved** on
   `feat/income-identity-dedupe`. Identity, not resemblance, is the key: only rows sharing
   an `id` merge, because the merge is irreversible — `IncomeSource` has no `mergedInto`
   and `SchemaV1` is frozen — and a wrong one *understates* chargeable income, the
   dangerous direction under ledger ruling 11. Onboarding now calls
   `TaxStore.seedPrimaryEmployment`, which owns a well-known identity and is create-only,
   so seeding twice writes one row. Duplicates are resolved at the *read* boundary by
   `ResolvedIncomeSource.resolving(_:)`, so the figure is correct before any sweep runs;
   `reconcileIncomeSources()` merely persists the same policy. No `SchemaV2` was needed.

## Carried forward from the identity dedupe

9. **Two sources that merely look alike are never merged.** Same name, same kind, different
   `id` stays two rows, deliberately — that is the overstating, and therefore conservative,
   direction, and it is the honest one when nothing can prove the rows are the same job.
   Closing it needs a merge screen where a person confirms, plus a `mergedInto` column to
   undo it with, which is a `SchemaV2`. Pinned by `sources with different ids are left
   alone even when they share a name`.
10. **A tie anywhere in an identity group blocks the whole group from collapsing**, not
   only a tie for the survivor. `isSafeToCollapse` refuses when any two adjacent rows share
   both `updatedAt` and their content key; when the tie is between two losers the collapse
   would still be deterministic. Over-conservative rather than wrong — the reads resolve
   the group either way, so the only cost is that the duplicate rows stay on disk.
11. **`endedOn` is not gap-filled across an identity group**, unlike `deductsEPF` and
   `deductsSOCSO`. `IncomeRecordEditorViewModel` writes it back to `nil` when the user
   clears an end date, so `nil` there is a real answer — "still paying" — and adopting a
   losing row's stale end date would silently re-end a reopened job. If a future build ever
   stops letting the user clear it, revisit this.
12. **The sweep runs on launch and on foregrounding, not on sync completion.** A duplicate
   arriving while the app is open reads correctly straight away and is collapsed at the
   next foregrounding. A real `NSPersistentCloudKitContainer` remote-change event would be
   better and is its own unit of work.
