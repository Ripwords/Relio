# Persistence, Sync and the iOS Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist a taxpayer's years, dependents, entries and documents in CloudKit-mirroring-safe SwiftData behind a single actor write path, project that graph into the shape TaxKit's evaluator already consumes, and put an iPhone app on top of it that answers "how much am I leaving on the table".

**Architecture:** Three layers, each testable without the one above it. `TaxData` owns every `@Model` type, the `TaxStore` actor that is the only thing allowed to write, deduplication, the reconciliation sweep, and the projection into `TaxYearSnapshot`/`EntrySnapshot`. `TaxPresentation` holds one `@Observable` view model per screen and imports `Observation`, never SwiftUI, so every decision a screen makes is covered by `swift test`. The SwiftUI target holds views that are bindings and layout only. `TaxKit` is not modified except to pay off one piece of debt Plan 1 deferred, and must keep compiling with no SwiftData or SwiftUI import.

**Tech Stack:** Swift 6.3, Swift Package Manager (tools 6.2), SwiftData, CryptoKit (SHA-256), Observation, SwiftUI, XcodeGen 2.x, swift-testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-08-23-malaysian-tax-relief-tracker-design.md`

**Predecessor:** `docs/superpowers/plans/2026-08-23-taxkit-foundation-and-rules-engine.md` (complete; 136 tests, 15 suites). Its execution ledger at `docs/superpowers/logs/2026-08-23-taxkit-execution-ledger.md` records four items explicitly parked for this plan; each is picked up by a named task below.

## Global Constraints

Every constraint from Plan 1 still applies. Repeated here because a task's implementer
reads this section and their own task, and nothing else:

- Swift tools version `6.2`; platforms `.iOS(.v26)`, `.macOS(.v26)`, `.watchOS(.v26)`.
- Strict concurrency: every public type is `Sendable`. No `@unchecked Sendable`.
- **No `Double` in any calculation path.** The only `Double` in the package is
  `Money.lossyDoubleForCharting`.
- Money is always whole sen. `RM 2,500.00` is `Money(sen: 250_000)`.
- One formatter only: `Money.formatted()` produces `RM 2,500.00`. Interpolating an amount
  into user-facing text anywhere else is a defect.
- TDD: the failing test is written and observed failing before the implementation, in
  every task.
- Conventional Commits (`feat:`, `fix:`, `test:`, `chore:`, `docs:`).

New to this plan:

- **`TaxKit` stays pure.** `grep -rn "import SwiftData\|import SwiftUI" Sources/TaxKit`
  must return nothing. Persistence lives in `TaxData`, which depends on `TaxKit`; the
  dependency never points the other way.
- **Every `@Model` attribute is optional or has a default; every relationship is
  optional; no `@Attribute(.unique)` anywhere.** CloudKit mirroring rejects all three.
  This is enforced by a test that walks `Schema.entities`, not by review.
- **Enums, `ReliefCode` and `Money` are stored as their raw `String`/`Int` with a
  computed accessor.** `#Predicate` can compare `String` and `Int` and push the
  comparison into the store; it cannot do so through a custom `Codable` type. Spec §11.4
  requires predicates push into SwiftData, so the storage type is the raw one and the
  computed property carries the meaning.
- **Every write goes through `TaxStore`.** No view, view model or test outside
  `TaxDataTests` touches a `ModelContext`. `TaxStore` stamps `updatedAt` and recomputes
  `dedupeKey` on every write, so the sync story cannot rot through a forgotten call.
- **Soft delete everywhere.** `deletedAt: Date?`; nothing is ever hard-deleted. Every
  read path filters `deletedAt == nil`.
- **Opportunity lists key off `eligibility` and `taxSaved`, never `headroom`.** Carried
  forward from Plan 1's final review: an `.ineligible` relief still reports `headroom`
  equal to its cap while `allowed` is zero, so a UI built on `headroom` alone would
  advertise reliefs the user cannot claim. Ranking and filtering use
  `taxSaved != nil`; `headroom` is display-only on rows that already passed that gate.
- **No `Date()` inside a computation.** Ages, dedupe keys and sweeps take an explicit
  date or calendar. The engine's determinism is the reason its golden files are worth
  anything, and the persistence layer must not undo it.
- **Dates that reach a hash or an age are resolved in `Asia/Kuala_Lumpur` on a
  `.gregorian` calendar.** A device in another time zone must produce the same
  `dedupeKey`, or the reconciliation sweep would fail to converge.

## What this plan does not build

Named so scope does not drift, and because a reviewer should not report them as gaps:

- The document pipeline — capture, OCR, MyInvois QR, the iCloud Drive ubiquity container,
  `NSMetadataQuery` download states. The `Document` and `DocumentFile` **models** are
  built here because schema V1 must be complete on the first commit; the machinery that
  fills them is spec §9 and its own plan.
- The Compare screen and the requirement-check UI (spec §15.6).
- The assistant, its tools and the Opportunities fallback (spec §15.7).
- watchOS, widgets, App Intents, the Share Extension, Mac refinements (spec §15.8–9).
- End-to-end CloudKit sync verification. See "Definition of done".

## File Structure

```
project.yml                                  XcodeGen spec — the .xcodeproj is generated
Config/Signing.example.xcconfig              committed template
Config/Signing.xcconfig                      gitignored — DEVELOPMENT_TEAM lives here
Package.swift                                + TaxData, TaxPresentation, 2 test targets

Sources/TaxData/
  Models/
    TaxYear.swift                            the year, its income facts, its entries
    Dependent.swift                          Dependent, DependentYearStatus, DependentKind
    ReliefEntry.swift                        one logged claim
    Document.swift                           a receipt's metadata and thumbnail
    DocumentFile.swift                       the bytes' identity and download state
    ChatMessage.swift                        assistant transcript (model only)
    UserPreferences.swift                    accent, assistant on/off, income module
  Schema/
    SchemaV1.swift                           VersionedSchema — the shipped shape
    TaxMigrationPlan.swift                   SchemaMigrationPlan, V1 only for now
    ModelContainerFactory.swift              in-memory / local-only / CloudKit
  Store/
    TaxStore.swift                           @ModelActor — the only write path
    TaxStore+Reads.swift                     fetches, all filtering deletedAt == nil
  Dedupe/
    Normalisation.swift                      vendor and date canonicalisation
    DedupeKey.swift                          SHA-256 over the normalised tuple
    Reconciliation.swift                     the deterministic sweep
  Projection/
    AgeCalculator.swift                      age at 31 December, fixed calendar
    Projection.swift                         @Model graph -> the engine's snapshots

Sources/TaxPresentation/
  YearContext.swift                          load ruleset + project + evaluate, once
  MoneyParsing.swift                         typed text -> Money, no Double
  HomeViewModel.swift                        the headline, the prompts, the top three
  ReliefsListViewModel.swift                 every relief, grouped and ranked
  ReliefDetailViewModel.swift                one relief: cap, entries, documents, source
  EntryEditorViewModel.swift                 create / edit / delete one entry
  OnboardingViewModel.swift                  three skippable screens

App/TaxTracker/
  TaxTrackerApp.swift                        @main, container wiring
  RootView.swift                             tabs, year switcher, onboarding gate
  Home/HomeView.swift
  Reliefs/ReliefsListView.swift
  Reliefs/ReliefDetailView.swift
  Entries/EntryEditorView.swift
  Onboarding/OnboardingView.swift
  Support/UndoToast.swift
  Support/MoneyText.swift                    the only place an amount becomes a View
  Support/Routes.swift                       ReliefsRoute, EntryRoute navigation values
  Info.plist
  TaxTracker.entitlements

Tests/TaxDataTests/
  SchemaInvariantTests.swift                 the CloudKit-safety walk
  ModelTests.swift                           defaults, relationships, inverse wiring
  MigrationTests.swift                       V1 container opens, round-trips
  TaxStoreTests.swift                        write path, stamping, soft delete
  DedupeTests.swift                          key stability and sensitivity
  ReconciliationTests.swift                  convergence, link union, mergedInto
  ProjectionTests.swift                      ages, claim history, entry mapping
  PersistedGoldenTests.swift                 store -> project -> evaluate == golden

Tests/TaxPresentationTests/
  YearContextTests.swift
  HomeViewModelTests.swift
  ReliefsViewModelTests.swift
  EntryEditorViewModelTests.swift
  OnboardingViewModelTests.swift
  FormattingDisciplineTests.swift
```

---

### Task 1: The `TaxData` target, the first two models, and the CloudKit-safety harness

**Files:**
- Modify: `Package.swift` (add `TaxData` product, target and test target)
- Create: `Sources/TaxData/Models/TaxYear.swift`
- Create: `Sources/TaxData/Models/Dependent.swift`
- Test: `Tests/TaxDataTests/SchemaInvariantTests.swift`
- Test: `Tests/TaxDataTests/ModelTests.swift`
- Test: `Tests/TaxKitTests/RulebookIntegrityTests.swift` (append one test — carried-forward debt)

**Interfaces:**
- Consumes: `Money`, `MaritalStatus`, `AssessmentType`, `EmploymentType`, `Gender`,
  `EducationLevel` from `TaxKit`.
- Produces:
  - `@Model final class TaxYear` with raw-storage properties and computed accessors.
  - `@Model final class Dependent`, `struct DependentYearStatus`, `enum DependentKind`.
  - `enum SchemaInvariants { static func violations(in: Schema) -> [String] }` — the
    reusable harness every later model task re-runs.

**Why raw storage.** `maritalStatusRaw: String?` with a computed `maritalStatus:
MaritalStatus?` rather than storing the enum directly. `#Predicate` can compare a `String`
and push the comparison into SQLite; through a `Codable` enum it cannot, and the fetch
degrades to loading every row and filtering in memory. Spec §11.4 budgets no frame over
8 ms, which that would blow on a seven-year archive. The same reasoning applies to
`Money` (stored `Int` sen) and, from Task 2, `ReliefCode` (stored `String`).

**Carried-forward debt.** Plan 1's final review parked this: "a `.not` wrapped around a
dependent predicate would get inverted existential semantics under Ruling A. Zero `not`
ops exist in any shipped rulebook, verified by grep. Plan 2 should add a
rulebook-integrity test forbidding `not` over dependent facts until the semantics are
defined." Steps 8–10 pay it off. It lands here because this is the first task in the plan
and the debt is a guard, not a feature — it should be in place before anyone edits a
rulebook again.

- [ ] **Step 1: Write the failing schema-invariant test**

Create `Tests/TaxDataTests/SchemaInvariantTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import TaxData

/// Walks a `Schema` and reports every property that would break CloudKit mirroring.
///
/// Spec §5 states the three rules as a convention. A convention is one distracted commit
/// from being false, and the failure mode is not a compile error — it is a container that
/// refuses to open on a user's device after the app has shipped. So it is a test, and
/// every task that adds a `@Model` type re-runs it.
enum SchemaInvariants {

    static func violations(in schema: Schema) -> [String] {
        var problems: [String] = []
        for entity in schema.entities.sorted(by: { $0.name < $1.name }) {
            for attribute in entity.attributes.sorted(by: { $0.name < $1.name }) {
                if attribute.isUnique {
                    problems.append("\(entity.name).\(attribute.name): CloudKit forbids unique constraints")
                }
                if !attribute.isOptional && attribute.defaultValue == nil {
                    problems.append("\(entity.name).\(attribute.name): non-optional with no default")
                }
            }
            for relationship in entity.relationships.sorted(by: { $0.name < $1.name }) {
                if !relationship.isOptional {
                    problems.append("\(entity.name).\(relationship.name): relationship must be optional")
                }
            }
        }
        return problems
    }
}

@Suite("Schema invariants") struct SchemaInvariantTests {

    /// Every `@Model` type in the package. Task 2 and Task 3 append to this list; the
    /// single source of truth for it becomes `SchemaV1.models` in Task 3.
    static let allModels: [any PersistentModel.Type] = [TaxYear.self, Dependent.self]

    @Test("every model is CloudKit-mirroring-safe")
    func modelsAreMirroringSafe() {
        let problems = SchemaInvariants.violations(in: Schema(Self.allModels))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Proves the harness is not vacuous. A deliberately malformed model must be caught.
    @Test("the harness detects a non-optional relationship and a missing default")
    func harnessIsNotVacuous() {
        let problems = SchemaInvariants.violations(in: Schema([BadModel.self, BadParent.self]))
        #expect(problems.contains { $0.contains("BadModel.noDefault") })
        #expect(problems.contains { $0.contains("BadParent.children") })
    }
}

@Model final class BadModel {
    var noDefault: String
    var parent: BadParent?
    init(noDefault: String) { self.noDefault = noDefault }
}

@Model final class BadParent {
    var label: String = ""
    @Relationship(inverse: \BadModel.parent) var children: [BadModel] = []
    init() {}
}
```

- [ ] **Step 2: Write the failing model test**

Create `Tests/TaxDataTests/ModelTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
import TaxKit
@testable import TaxData

@Suite("Models") struct ModelTests {

    @Test("a fresh TaxYear is empty rather than wrong")
    func freshYearIsEmpty() {
        let year = TaxYear(year: 2025)
        #expect(year.year == 2025)
        #expect(year.grossIncome == nil)
        #expect(year.maritalStatus == nil)
        #expect(year.deletedAt == nil)
        // distantPast, not Date(): "never stamped" must be detectable, and a default
        // that reads the clock would make two devices disagree about an untouched row.
        #expect(year.updatedAt == .distantPast)
    }

    @Test("computed accessors round-trip through raw storage")
    func accessorsRoundTrip() {
        let year = TaxYear(year: 2025)

        year.grossIncome = Money(ringgit: 128_000)
        #expect(year.grossIncomeSen == 12_800_000)
        #expect(year.grossIncome == Money(ringgit: 128_000))

        year.maritalStatus = .married
        #expect(year.maritalStatusRaw == "married")
        #expect(year.maritalStatus == .married)

        year.assessmentType = .separate
        year.employmentType = .privateSector
        year.gender = .female
        #expect(year.assessmentType == .separate)
        #expect(year.employmentType == .privateSector)
        #expect(year.gender == .female)

        year.grossIncome = nil
        #expect(year.grossIncomeSen == nil)
    }

    @Test("an unrecognised raw value reads as nil rather than trapping")
    func unknownRawValueIsNil() {
        let year = TaxYear(year: 2025)
        // A future schema version, or a device running an older build, can put a value
        // here this build has never heard of. Unknown must degrade to "not yet known",
        // which the engine already renders as .needsInfo, never crash the app.
        year.maritalStatusRaw = "civilPartnership"
        #expect(year.maritalStatus == nil)
    }

    @Test("a dependent's year statuses are stored inline and keyed by year")
    func dependentYearStatuses() {
        let child = Dependent(name: "Farah")
        child.kind = .child
        child.yearStatuses = [
            DependentYearStatus(year: 2024, educationLevel: .preTertiary, claimPercentage: 100, isFullTime: true),
            DependentYearStatus(year: 2025, educationLevel: .tertiaryLocal, claimPercentage: 50, isFullTime: true)
        ]
        #expect(child.status(for: 2025)?.educationLevel == .tertiaryLocal)
        #expect(child.status(for: 2025)?.claimPercentage == 50)
        #expect(child.status(for: 2023) == nil)
    }

    @Test("a dependent with no recorded status for the year yields nil, not a default")
    func missingStatusIsNil() {
        let child = Dependent(name: "Danish")
        // Defaulting to .none here would silently tell the engine "not in education",
        // which reads as ineligible for the education reliefs. nil reaches the engine as
        // an unanswered question and surfaces as a prompt instead.
        #expect(child.status(for: 2025) == nil)
    }

    @Test("an unasked disability question is nil, not false")
    func disabilityStartsUnknown() {
        let child = Dependent(name: "Danish")
        // false would mean "confirmed not disabled". Before the app asks, it knows
        // nothing, and the engine renders nothing as a prompt worth RM 6,000. Storing
        // false here would silently refuse the relief and never explain why.
        #expect(child.isDisabled == nil)
    }
}
```

- [ ] **Step 3: Run both tests to verify they fail**

Run: `swift test --filter TaxDataTests`
Expected: FAIL — the `TaxData` module does not exist yet
("no such module 'TaxData'").

- [ ] **Step 4: Add the target to `Package.swift`**

Modify `Package.swift` — add to `products` and `targets`:

```swift
    products: [
        .library(name: "TaxKit", targets: ["TaxKit"]),
        .library(name: "TaxData", targets: ["TaxData"])
    ],
```

```swift
        .target(
            name: "TaxData",
            dependencies: ["TaxKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
```

and after the existing `TaxKitTests` target:

```swift
        .testTarget(
            name: "TaxDataTests",
            dependencies: ["TaxData"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
```

- [ ] **Step 5: Write `TaxYear`**

Create `Sources/TaxData/Models/TaxYear.swift`:

```swift
import Foundation
import SwiftData
import TaxKit

/// One Year of Assessment for one taxpayer: their income facts and their entries.
///
/// Every stored property is optional or defaulted and no relationship is required,
/// because CloudKit mirroring rejects both. `SchemaInvariantTests` enforces this.
///
/// Enums and money are stored as raw `String`/`Int`. `#Predicate` pushes comparisons on
/// those into the store; through a `Codable` enum it would load every row and filter in
/// memory. The computed accessors below are the API; the `Raw` properties are storage.
@Model
public final class TaxYear {

    /// Stable across devices, like every other model here. `persistentModelID` is a
    /// local store identity and is not guaranteed equal on two devices for the same
    /// logical row, so it cannot serve as the tie-break that makes duplicate resolution
    /// converge.
    public var id: UUID = UUID()
    public var year: Int = 0

    public var grossIncomeSen: Int?
    public var epfSen: Int?
    public var socsoSen: Int?

    public var maritalStatusRaw: String?
    public var spouseHasIncome: Bool?
    public var assessmentTypeRaw: String?
    public var employmentTypeRaw: String?
    public var genderRaw: String?

    /// Purchase price of the first home, for the tiered housing-loan-interest relief.
    public var propertyPriceSen: Int?

    /// JKM-registered disability, gating the two disabled-person reliefs.
    public var selfIsDisabled: Bool?
    public var spouseIsDisabled: Bool?

    /// `.distantPast` means "never written through TaxStore". Reading the clock in a
    /// default would make two devices disagree about a row neither has touched.
    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    public init(year: Int = 0) {
        self.year = year
    }
}

extension TaxYear {

    public var grossIncome: Money? {
        get { grossIncomeSen.map(Money.init(sen:)) }
        set { grossIncomeSen = newValue?.sen }
    }

    public var epf: Money? {
        get { epfSen.map(Money.init(sen:)) }
        set { epfSen = newValue?.sen }
    }

    public var socso: Money? {
        get { socsoSen.map(Money.init(sen:)) }
        set { socsoSen = newValue?.sen }
    }

    public var maritalStatus: MaritalStatus? {
        get { maritalStatusRaw.flatMap(MaritalStatus.init(rawValue:)) }
        set { maritalStatusRaw = newValue?.rawValue }
    }

    public var assessmentType: AssessmentType? {
        get { assessmentTypeRaw.flatMap(AssessmentType.init(rawValue:)) }
        set { assessmentTypeRaw = newValue?.rawValue }
    }

    public var employmentType: EmploymentType? {
        get { employmentTypeRaw.flatMap(EmploymentType.init(rawValue:)) }
        set { employmentTypeRaw = newValue?.rawValue }
    }

    public var gender: Gender? {
        get { genderRaw.flatMap(Gender.init(rawValue:)) }
        set { genderRaw = newValue?.rawValue }
    }

    public var isLive: Bool { deletedAt == nil }
}
```

- [ ] **Step 6: Write `Dependent`**

Create `Sources/TaxData/Models/Dependent.swift`:

```swift
import Foundation
import SwiftData
import TaxKit

public enum DependentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case child, parent, grandparent
}

/// A dependent's circumstances for one Year of Assessment.
///
/// Stored inline on `Dependent` as a `Codable` value rather than as its own entity:
/// education level and claim share change per YA, but the edit frequency is near zero
/// and keeping it inline holds the CloudKit relationship graph flat. Spec §5.
public struct DependentYearStatus: Codable, Hashable, Sendable {
    public var year: Int
    public var educationLevel: EducationLevel
    /// 100 when claimed in full, 50 when split with a spouse.
    public var claimPercentage: Int
    public var isFullTime: Bool

    public init(year: Int = 0,
                educationLevel: EducationLevel = .none,
                claimPercentage: Int = 100,
                isFullTime: Bool = true) {
        self.year = year
        self.educationLevel = educationLevel
        self.claimPercentage = claimPercentage
        self.isFullTime = isFullTime
    }
}

/// A member of the household a relief can be claimed for.
///
/// Deliberately has no relationship to `TaxYear`. Dependents outlive any one year, and
/// `ReliefEntry` refers to one by `dependentID: UUID` rather than by relationship, which
/// keeps the mirrored graph flat and makes a dangling reference a recoverable data issue
/// rather than a broken object graph.
@Model
public final class Dependent {

    public var id: UUID = UUID()
    public var name: String = ""
    public var dateOfBirth: Date?
    public var kindRaw: String = DependentKind.child.rawValue
    /// Optional on purpose. `false` would mean "confirmed not disabled"; what the app
    /// actually has before it asks is *nothing*. `DependentSnapshot.isDisabled` is
    /// `Bool?` for the same reason, and the engine turns nil into a prompt worth
    /// RM 6,000 rather than a silent ineligibility. Spec §7, three-valued eligibility.
    public var isDisabled: Bool?
    public var yearStatuses: [DependentYearStatus] = []

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    public init(id: UUID = UUID(), name: String = "") {
        self.id = id
        self.name = name
    }
}

extension Dependent {

    public var kind: DependentKind {
        get { DependentKind(rawValue: kindRaw) ?? .child }
        set { kindRaw = newValue.rawValue }
    }

    /// The recorded status for a year, or `nil` when nothing has been recorded.
    ///
    /// `nil` rather than a `.none` default on purpose: defaulting would tell the engine
    /// "not in education", which reads as ineligible for the education reliefs. `nil`
    /// reaches the engine as an unanswered question and surfaces as a prompt.
    public func status(for year: Int) -> DependentYearStatus? {
        yearStatuses.first { $0.year == year }
    }

    public var isLive: Bool { deletedAt == nil }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter TaxDataTests`
Expected: PASS — 6 tests in 2 suites.

- [ ] **Step 8: Write the failing `not`-over-dependent-facts guard**

Append to `Tests/TaxKitTests/RulebookIntegrityTests.swift`, inside the existing suite:

```swift
    /// Carried forward from Plan 1's final review.
    ///
    /// A dependent predicate is satisfied when ANY dependent satisfies it (existential).
    /// Wrapping one in `.not` therefore means "no dependent satisfies it", which is not
    /// the negation a rulebook author would expect to write, and nothing in the decoder
    /// stops them. Zero `not` ops exist over dependent facts in any shipped rulebook, so
    /// this guard costs nothing today and refuses the construct until the semantics are
    /// defined and tested.
    @Test("no shipped rulebook wraps a dependent fact in `not`", arguments: shippedYears)
    func noNotOverDependentFacts(year: Int) throws {
        for relief in try Self.load(year).allReliefs {
            guard let predicate = relief.eligibility else { continue }
            #expect(!Self.containsNotOverDependentFact(predicate),
                    "\(year) \(relief.code): `not` over a dependent fact has undefined semantics")
        }
    }

    /// True when any `.not` in the tree has a dependent fact anywhere beneath it.
    static func containsNotOverDependentFact(_ predicate: EligibilityPredicate) -> Bool {
        func mentionsDependent(_ node: EligibilityPredicate) -> Bool {
            switch node {
            case .dependentAge, .dependentEducation, .dependentIsDisabled:
                return true
            case .not(let inner):
                return mentionsDependent(inner)
            case .all(let children), .any(let children):
                return children.contains(where: mentionsDependent)
            default:
                return false
            }
        }
        switch predicate {
        case .not(let inner):
            return mentionsDependent(inner)
        case .all(let children), .any(let children):
            return children.contains(where: containsNotOverDependentFact)
        default:
            return false
        }
    }
```

The three dependent cases are `dependentAge`, `dependentEducation` and
`dependentIsDisabled`; the combinators are `all` and `any`, not `and`/`or`. `Self.load`
and `shippedYears` are the helpers the suite already has.

- [ ] **Step 9: Run the guard and verify it passes non-vacuously**

Run: `swift test --filter RulebookIntegrity`
Expected: PASS.

Then prove it is not vacuous. Temporarily wrap one dependent predicate in the YA2025
rulebook JSON in a `not`, re-run, and confirm the test FAILS naming that relief. Revert
the JSON edit. A guard that has never been observed failing is not a guard.

- [ ] **Step 10: Run the whole suite and commit**

Run: `swift test`
Expected: PASS — 136 existing tests plus 6 new, no regressions.

```bash
git add Package.swift Sources/TaxData Tests/TaxDataTests Tests/TaxKitTests/RulebookIntegrityTests.swift
git commit -m "feat: add the TaxData target with TaxYear, Dependent and a CloudKit-safety harness"
```

---

### Task 2: `ReliefEntry`, `Document`, `DocumentFile` and the many-to-many graph

**Files:**
- Create: `Sources/TaxData/Models/ReliefEntry.swift`
- Create: `Sources/TaxData/Models/Document.swift`
- Create: `Sources/TaxData/Models/DocumentFile.swift`
- Modify: `Sources/TaxData/Models/TaxYear.swift` (add the `entries` relationship)
- Modify: `Tests/TaxDataTests/SchemaInvariantTests.swift` (extend `allModels`)
- Test: `Tests/TaxDataTests/ModelTests.swift` (append)

**Interfaces:**
- Consumes: `TaxYear` from Task 1; `ReliefCode`, `Claimant`, `DocumentKind`, `Money`
  from `TaxKit`.
- Produces:
  - `@Model final class ReliefEntry` — `reliefCode`, `amount`, `claimant`,
    `dependentID`, `vendor`, `spentOn`, `dedupeKey`, `needsDocument`, `mergedInto`,
    `taxYear`, `documents`.
  - `@Model final class Document` — `kind`, `vendor`, `documentDate`, `total`,
    `ocrText`, `eInvoiceUUID`, `thumbnail`, `entries`, `file`.
  - `@Model final class DocumentFile`, `enum DownloadState`.
  - `TaxYear.entries: [ReliefEntry]?`.

**Deviation from spec §5 and §6.1 — the entry owns `vendor` and `spentOn`.** The spec
puts `vendor` and `documentDate` on `Document`, but defines `ReliefEntry.dedupeKey` as
the SHA-256 of `(reliefCode, amount.sen, documentDate, vendor.normalised())`. Those two
statements cannot both hold: an entry typed by hand has no `Document`, so two of its four
key components would be undefined and every document-less entry would collapse to the
same key. Manual entry is the primary path — spec §1 requires logging a first receipt in
30 seconds without an account — so the entry carries its own `vendor` and `spentOn`.
`Document` keeps its own pair, populated by OCR in a later plan; the two are independent,
and reconciling a mismatch between them is a document-pipeline concern, not this plan's.
Cost if wrong: the dedupe key would need recomputing across the store, which Task 5's
`TaxStore.recomputeAllDedupeKeys()` already exists to do.

**Deviation from spec §5 — `claimedFor` is named `claimant`.** `EntrySnapshot.claimant`
is what the engine consumes and what Task 7 projects into. Two names for one concept
across a seam is a bug waiting for a careless implementer; the engine's name wins.

**`DownloadState` carries an `Int` percentage, not a `Double`.** Spec §6 writes
`.downloading(Double)`. The package forbids `Double` outside
`Money.lossyDoubleForCharting`, and a progress bar does not need sub-percent resolution.
Stored as a raw `String` plus an `Int` 0...100.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TaxDataTests/ModelTests.swift`:

```swift
@Suite("Entry and document graph") struct EntryGraphTests {

    @Test("an entry round-trips its code, amount and claimant through raw storage")
    func entryAccessors() {
        let entry = ReliefEntry()
        entry.reliefCode = ReliefCode("LIFESTYLE")
        entry.amount = Money(ringgit: 1_820)
        entry.claimant = .individual

        #expect(entry.reliefCodeRaw == "LIFESTYLE")
        #expect(entry.amountSen == 182_000)
        #expect(entry.claimantRaw == "self")
        #expect(entry.reliefCode == ReliefCode("LIFESTYLE"))
        #expect(entry.amount == Money(ringgit: 1_820))
        #expect(entry.claimant == .individual)
    }

    @Test("an unrecognised claimant reads as individual rather than trapping")
    func unknownClaimantFallsBack() {
        let entry = ReliefEntry()
        entry.claimantRaw = "cousin"
        // A relief claimed for an unknown party is still the taxpayer's own claim as far
        // as this build can tell. Falling back keeps the row visible and editable; a trap
        // would take the whole list down over one bad row synced from a newer device.
        #expect(entry.claimant == .individual)
    }

    @Test("an entry belongs to a year and the year lists it")
    func entryYearInverse() throws {
        let container = try ModelContainer(
            for: Schema(SchemaInvariantTests.allModels),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let year = TaxYear(year: 2025)
        let entry = ReliefEntry()
        entry.reliefCode = ReliefCode("LIFESTYLE")
        entry.taxYear = year
        context.insert(year)
        context.insert(entry)
        try context.save()

        #expect(year.entries?.count == 1)
        #expect(year.entries?.first?.reliefCode == ReliefCode("LIFESTYLE"))
        #expect(entry.taxYear?.year == 2025)
    }

    @Test("one document can back two entries and one entry can hold two documents")
    func documentsAreManyToMany() throws {
        let container = try ModelContainer(
            for: Schema(SchemaInvariantTests.allModels),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        // Spec §5: a serious-illness claim needs a receipt AND a medical certificate,
        // and one hospital bill can back two different entries. Both directions matter,
        // and Task 6's sweep unions these links when it merges duplicates.
        let bill = Document(); bill.kind = .officialReceipt
        let certificate = Document(); certificate.kind = .medicalCertificate

        let serious = ReliefEntry(); serious.reliefCode = ReliefCode("MEDICAL_SERIOUS")
        let checkup = ReliefEntry(); checkup.reliefCode = ReliefCode("MEDICAL_CHECKUP")

        for object in [bill, certificate] { context.insert(object) }
        for object in [serious, checkup] { context.insert(object) }
        serious.documents = [bill, certificate]
        checkup.documents = [bill]
        try context.save()

        #expect(serious.documents?.count == 2)
        #expect(checkup.documents?.count == 1)
        #expect(bill.entries?.count == 2)
        #expect(certificate.entries?.count == 1)
    }

    @Test("download state round-trips without a Double")
    func downloadState() {
        let file = DocumentFile()
        file.downloadState = .downloading(percent: 42)
        #expect(file.downloadStateRaw == "downloading")
        #expect(file.downloadProgressPercent == 42)
        #expect(file.downloadState == .downloading(percent: 42))

        file.downloadState = .local
        #expect(file.downloadProgressPercent == 100)
        #expect(file.downloadState == .local)

        file.downloadState = .missing
        #expect(file.downloadState == .missing)
    }

    @Test("a percentage outside 0...100 is clamped rather than stored")
    func downloadProgressIsClamped() {
        let file = DocumentFile()
        file.downloadState = .downloading(percent: 250)
        #expect(file.downloadProgressPercent == 100)
        file.downloadState = .downloading(percent: -5)
        #expect(file.downloadProgressPercent == 0)
    }

    @Test("all five models remain CloudKit-mirroring-safe")
    func stillMirroringSafe() {
        let problems = SchemaInvariants.violations(in: Schema(SchemaInvariantTests.allModels))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
}
```

Modify the model list in `Tests/TaxDataTests/SchemaInvariantTests.swift`:

```swift
    static let allModels: [any PersistentModel.Type] = [
        TaxYear.self, Dependent.self, ReliefEntry.self, Document.self, DocumentFile.self
    ]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TaxDataTests`
Expected: FAIL — "cannot find 'ReliefEntry' in scope".

- [ ] **Step 3: Write `ReliefEntry`**

Create `Sources/TaxData/Models/ReliefEntry.swift`:

```swift
import Foundation
import SwiftData
import TaxKit

/// One logged claim: an amount against a relief code, in one Year of Assessment.
///
/// Refers to its rule by `ReliefCode` and never by relationship. The rulebook is bundled
/// JSON, not database rows, so when YA2026 renames or splits a category these rows do not
/// migrate — the engine resolves the code against whichever ruleset applies. Spec §5
/// calls this the most important decoupling in the design.
@Model
public final class ReliefEntry {

    public var id: UUID = UUID()
    public var reliefCodeRaw: String = ""
    public var amountSen: Int = 0
    public var claimantRaw: String = Claimant.individual.rawValue

    /// Which dependent this is claimed for, by identity rather than by relationship.
    /// A dangling id is a recoverable data issue; a broken object graph is not.
    public var dependentID: UUID?

    /// The entry's own vendor and date. See the deviation note in the plan: the dedupe
    /// key needs both, and a hand-typed entry has no `Document` to borrow them from.
    public var vendor: String = ""
    public var spentOn: Date?
    public var note: String = ""

    /// SHA-256 over the normalised identifying tuple. Written only by `TaxStore`.
    public var dedupeKey: String = ""

    /// Cached answer to "is this claim missing a document the rulebook requires".
    /// Denormalised because `#Predicate` cannot call the engine, and the Documents tab
    /// filters on it. Recomputed by `TaxStore` on every write to this entry.
    public var needsDocument: Bool = false

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    /// Set by the reconciliation sweep when this row lost to a duplicate, so the merge
    /// is auditable and reversible rather than a silent disappearance.
    public var mergedInto: UUID?

    public var taxYear: TaxYear?

    @Relationship(inverse: \Document.entries)
    public var documents: [Document]?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

extension ReliefEntry {

    public var reliefCode: ReliefCode {
        get { ReliefCode(reliefCodeRaw) }
        set { reliefCodeRaw = newValue.rawValue }
    }

    public var amount: Money {
        get { Money(sen: amountSen) }
        set { amountSen = newValue.sen }
    }

    /// An unrecognised claimant falls back to the taxpayer rather than trapping: one bad
    /// row synced from a newer build must not take the whole list down.
    public var claimant: Claimant {
        get { Claimant(rawValue: claimantRaw) ?? .individual }
        set { claimantRaw = newValue.rawValue }
    }

    public var documentKinds: Set<DocumentKind> {
        Set((documents ?? []).filter(\.isLive).map(\.kind))
    }

    public var isLive: Bool { deletedAt == nil }
}
```

- [ ] **Step 4: Write `Document` and `DocumentFile`**

Create `Sources/TaxData/Models/Document.swift`:

```swift
import Foundation
import SwiftData
import TaxKit

/// A receipt, invoice or certificate: its metadata and a small thumbnail.
///
/// The full-resolution bytes do not live here and do not live in CloudKit. They go to the
/// app's iCloud Drive container, identified by `DocumentFile`. Only the ~30 KB thumbnail
/// is mirrored, which is what keeps a seven-year archive syncing to a Watch. Spec §6.
@Model
public final class Document {

    public var id: UUID = UUID()
    public var kindRaw: String = DocumentKind.officialReceipt.rawValue
    public var vendor: String = ""
    public var documentDate: Date?
    public var totalSen: Int?

    /// Populated by the document pipeline in a later plan. Nil here is normal.
    public var ocrText: String?
    /// From a MyInvois QR payload. The strongest dedupe key when present.
    public var eInvoiceUUID: String?
    /// ~30 KB. The only image bytes that sync.
    public var thumbnail: Data?

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    public var entries: [ReliefEntry]?
    public var file: DocumentFile?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

extension Document {

    public var kind: DocumentKind {
        get { DocumentKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    public var total: Money? {
        get { totalSen.map(Money.init(sen:)) }
        set { totalSen = newValue?.sen }
    }

    public var isLive: Bool { deletedAt == nil }
}
```

Create `Sources/TaxData/Models/DocumentFile.swift`:

```swift
import Foundation
import SwiftData

/// Where a document's bytes are and whether they are on this device.
///
/// Progress is an `Int` percentage, not the `Double` spec §6 sketches: the package bans
/// `Double` outside charting, and a progress bar does not need sub-percent resolution.
public enum DownloadState: Hashable, Sendable {
    case local
    case notDownloaded
    case downloading(percent: Int)
    case uploading
    /// The record exists but the file is gone — deleted in Files.app, most likely.
    /// Surfaces as a repairable amber row rather than a crash. Spec §6.
    case missing
}

@Model
public final class DocumentFile {

    public var id: UUID = UUID()
    /// Uniform Type Identifier, e.g. `public.jpeg`, `com.adobe.pdf`.
    public var uti: String = "public.jpeg"
    public var byteCount: Int = 0
    /// SHA-256 of the normalised bytes. Catches the same photo imported twice.
    public var contentHash: String = ""
    public var downloadStateRaw: String = "local"
    public var downloadProgressPercent: Int = 100

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    @Relationship(inverse: \Document.file)
    public var document: Document?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

extension DocumentFile {

    public var downloadState: DownloadState {
        get {
            switch downloadStateRaw {
            case "local": return .local
            case "notDownloaded": return .notDownloaded
            case "downloading": return .downloading(percent: downloadProgressPercent)
            case "uploading": return .uploading
            case "missing": return .missing
            default: return .notDownloaded
            }
        }
        set {
            switch newValue {
            case .local:
                downloadStateRaw = "local"
                downloadProgressPercent = 100
            case .notDownloaded:
                downloadStateRaw = "notDownloaded"
                downloadProgressPercent = 0
            case .downloading(let percent):
                downloadStateRaw = "downloading"
                downloadProgressPercent = Swift.min(100, Swift.max(0, percent))
            case .uploading:
                downloadStateRaw = "uploading"
            case .missing:
                downloadStateRaw = "missing"
                downloadProgressPercent = 0
            }
        }
    }

    public var isLive: Bool { deletedAt == nil }
}
```

- [ ] **Step 5: Add the `entries` relationship to `TaxYear`**

Modify `Sources/TaxData/Models/TaxYear.swift` — add before `init`:

```swift
    /// Cascade so deleting a year's record takes its entries with it. Note that nothing
    /// in the app hard-deletes a year; this is the safety net for a container reset.
    @Relationship(deleteRule: .cascade, inverse: \ReliefEntry.taxYear)
    public var entries: [ReliefEntry]?
```

and add to the extension:

```swift
    /// Entries that have not been soft-deleted or merged away.
    public var liveEntries: [ReliefEntry] {
        (entries ?? []).filter { $0.deletedAt == nil }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter TaxDataTests`
Expected: PASS — 13 tests in 3 suites.

- [ ] **Step 7: Commit**

```bash
git add Sources/TaxData Tests/TaxDataTests
git commit -m "feat: add ReliefEntry, Document and DocumentFile with the many-to-many graph"
```

---

### Task 3: `ChatMessage`, `UserPreferences`, and the versioned schema

**Files:**
- Create: `Sources/TaxData/Models/ChatMessage.swift`
- Create: `Sources/TaxData/Models/UserPreferences.swift`
- Create: `Sources/TaxData/Schema/SchemaV1.swift`
- Create: `Sources/TaxData/Schema/TaxMigrationPlan.swift`
- Create: `Sources/TaxData/Schema/ModelContainerFactory.swift`
- Modify: `Tests/TaxDataTests/SchemaInvariantTests.swift` (point `allModels` at `SchemaV1`)
- Test: `Tests/TaxDataTests/MigrationTests.swift`

**Interfaces:**
- Consumes: all five models from Tasks 1–2.
- Produces:
  - `@Model final class ChatMessage`, `enum ChatRole`.
  - `@Model final class UserPreferences`, `enum CaptureQuality`.
  - `enum SchemaV1: VersionedSchema` with `static var models`.
  - `enum TaxMigrationPlan: SchemaMigrationPlan`.
  - `enum TaxContainer { static func make(_ storage: Storage) throws -> ModelContainer }`
    with `Storage.inMemory | .localOnly(URL?) | .cloudKit(identifier: String?)`.

**Why `VersionedSchema` with one version and an empty stage list.** It looks like
ceremony today and it is not. Spec §5 requires it "from the first commit" because a
shipped store across four platforms cannot be wiped, and retrofitting a
`SchemaMigrationPlan` onto a container that was created without one means the V1 store
has no recorded version to migrate *from*. The cost now is fifteen lines; the cost later
is a data-loss bug on other people's devices.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TaxDataTests/MigrationTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
import TaxKit
@testable import TaxData

@Suite("Schema and container") struct MigrationTests {

    @Test("SchemaV1 lists every model in the package")
    func schemaIsComplete() {
        let names = Set(SchemaV1.models.map { String(describing: $0) })
        #expect(names == ["TaxYear", "Dependent", "ReliefEntry",
                          "Document", "DocumentFile", "ChatMessage", "UserPreferences"])
    }

    @Test("SchemaV1 is version 1.0.0")
    func schemaVersion() {
        #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }

    @Test("the migration plan names V1 and has no stages yet")
    func migrationPlan() {
        #expect(TaxMigrationPlan.schemas.count == 1)
        #expect(TaxMigrationPlan.stages.isEmpty)
    }

    @Test("every model in the shipped schema is CloudKit-mirroring-safe")
    func shippedSchemaIsMirroringSafe() {
        let problems = SchemaInvariants.violations(in: Schema(SchemaV1.models))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("an in-memory container opens and round-trips a year")
    func inMemoryContainerRoundTrips() throws {
        let container = try TaxContainer.make(.inMemory)
        let context = ModelContext(container)

        let year = TaxYear(year: 2025)
        year.grossIncome = Money(ringgit: 128_000)
        context.insert(year)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TaxYear>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.grossIncome == Money(ringgit: 128_000))
    }

    @Test("a local-only container is configured without CloudKit")
    func localOnlyHasNoCloudKit() throws {
        // The app must remain fully usable signed out of iCloud. Spec §6 failure mode 3.
        let container = try TaxContainer.make(.inMemory)
        #expect(container.configurations.allSatisfy { $0.cloudKitDatabase == .none })
    }

    @Test("chat history caps at the most recent 200 messages")
    func chatHistoryCap() {
        #expect(ChatMessage.historyLimit == 200)
    }

    @Test("preferences start with the assistant on and income off")
    func preferenceDefaults() {
        let preferences = UserPreferences()
        // Income is optional per spec §1: a user must be able to log a receipt without
        // entering it. Off by default is what makes the 30-second first launch possible.
        #expect(preferences.incomeModuleEnabled == false)
        #expect(preferences.assistantEnabled == true)
        #expect(preferences.hasCompletedOnboarding == false)
        #expect(preferences.captureQuality == .balanced)
    }
}
```

Modify `Tests/TaxDataTests/SchemaInvariantTests.swift` so the list has one home:

```swift
    /// The shipped schema is the single source of truth. A model that is not in
    /// `SchemaV1.models` does not exist as far as the container is concerned, so testing
    /// any other list would test something the app never opens.
    static let allModels: [any PersistentModel.Type] = SchemaV1.models
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TaxDataTests`
Expected: FAIL — "cannot find 'SchemaV1' in scope".

- [ ] **Step 3: Write `ChatMessage` and `UserPreferences`**

Create `Sources/TaxData/Models/ChatMessage.swift`:

```swift
import Foundation
import SwiftData

public enum ChatRole: String, Codable, Hashable, Sendable, CaseIterable {
    case user, assistant
}

/// One turn of the assistant transcript. The model type ships in schema V1 so the
/// assistant plan does not need a migration; nothing in this plan writes to it.
@Model
public final class ChatMessage {

    public var id: UUID = UUID()
    public var roleRaw: String = ChatRole.user.rawValue
    public var text: String = ""
    public var createdAt: Date = Date.distantPast
    /// The Year of Assessment the turn was about, so history can be scoped per year.
    public var year: Int = 0

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

extension ChatMessage {

    /// Spec §5: history is capped at the most recent 200 messages and prunable from
    /// Settings. Enforced by `TaxStore` when the assistant plan lands.
    public static let historyLimit = 200

    public var role: ChatRole {
        get { ChatRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    public var isLive: Bool { deletedAt == nil }
}
```

Create `Sources/TaxData/Models/UserPreferences.swift`:

```swift
import Foundation
import SwiftData

public enum CaptureQuality: String, Codable, Hashable, Sendable, CaseIterable {
    case compact, balanced, original
}

/// App-wide settings. Logically a singleton, but CloudKit cannot enforce that — two
/// devices first launching offline will each create one. `TaxStore.preferences()`
/// resolves the collision by keeping the newest and soft-deleting the rest, the same
/// rule the reconciliation sweep uses for entries.
@Model
public final class UserPreferences {

    public var id: UUID = UUID()
    /// Named accent from the app's palette, not a serialised colour.
    public var accentName: String = "default"
    public var assistantEnabled: Bool = true
    public var captureQualityRaw: String = CaptureQuality.balanced.rawValue
    /// Income is optional. Off by default is what makes spec §1's 30-second first
    /// launch possible — the app is useful before the user has entered a salary.
    public var incomeModuleEnabled: Bool = false
    public var hasCompletedOnboarding: Bool = false
    /// The year the user was last looking at, so launch resumes where they left off.
    public var lastViewedYear: Int = 0

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

extension UserPreferences {

    public var captureQuality: CaptureQuality {
        get { CaptureQuality(rawValue: captureQualityRaw) ?? .balanced }
        set { captureQualityRaw = newValue.rawValue }
    }

    public var isLive: Bool { deletedAt == nil }
}
```

- [ ] **Step 4: Write the schema, the migration plan and the container factory**

Create `Sources/TaxData/Schema/SchemaV1.swift`:

```swift
import Foundation
import SwiftData

/// The shipped store shape. Adding, removing or retyping a stored property here is a
/// schema change: bump to `SchemaV2`, add a `MigrationStage`, and never edit V1.
public enum SchemaV1: VersionedSchema {

    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [TaxYear.self,
         Dependent.self,
         ReliefEntry.self,
         Document.self,
         DocumentFile.self,
         ChatMessage.self,
         UserPreferences.self]
    }
}
```

Create `Sources/TaxData/Schema/TaxMigrationPlan.swift`:

```swift
import Foundation
import SwiftData

/// One version, no stages — deliberately. The plan exists from the first commit so the
/// V1 store records a version to migrate from. Retrofitting one later means a shipped
/// store with no recorded version, which is a data-loss bug on other people's devices.
public enum TaxMigrationPlan: SchemaMigrationPlan {

    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}
```

Create `Sources/TaxData/Schema/ModelContainerFactory.swift`:

```swift
import Foundation
import SwiftData

/// Builds the one container the app opens.
///
/// Three storages rather than a Bool, because the difference between them is not a
/// toggle: `.inMemory` is for tests, `.localOnly` is what a user signed out of iCloud
/// gets and must be fully functional, and `.cloudKit` is the shipping default. Spec §6
/// requires the app remain usable and account-less offline.
public enum TaxContainer {

    public enum Storage: Sendable {
        case inMemory
        /// `nil` uses SwiftData's default Application Support location.
        case localOnly(URL?)
        /// `nil` uses `.automatic`, which resolves the container from the entitlement.
        case cloudKit(identifier: String?)
    }

    public static func make(_ storage: Storage) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration: ModelConfiguration

        switch storage {
        case .inMemory:
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        case .localOnly(let url):
            if let url {
                configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            } else {
                configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            }

        case .cloudKit(let identifier):
            if let identifier {
                configuration = ModelConfiguration(schema: schema,
                                                   cloudKitDatabase: .private(identifier))
            } else {
                configuration = ModelConfiguration(schema: schema,
                                                   cloudKitDatabase: .automatic)
            }
        }

        return try ModelContainer(for: schema,
                                  migrationPlan: TaxMigrationPlan.self,
                                  configurations: configuration)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter TaxDataTests`
Expected: PASS — 21 tests in 4 suites.

**If `configuration.cloudKitDatabase == .none` does not compile** because
`ModelConfiguration.CloudKitDatabase` is not `Equatable` in this SDK, replace that
assertion in `localOnlyHasNoCloudKit` with a round-trip through the container instead:
insert a `TaxYear`, save, and assert `container.configurations.count == 1`. The point of
the test is that an in-memory container opens without an iCloud account present; keep
that, drop the equality check.

- [ ] **Step 6: Commit**

```bash
git add Sources/TaxData Tests/TaxDataTests
git commit -m "feat: add the versioned schema, migration plan and container factory"
```

---

### Task 4: `TaxStore` — the only write path

**Files:**
- Create: `Sources/TaxData/Store/TaxStore.swift`
- Create: `Sources/TaxData/Store/TaxStore+Reads.swift`
- Test: `Tests/TaxDataTests/TaxStoreTests.swift`

**Interfaces:**
- Consumes: every model, `TaxContainer` from Task 3.
- Produces:
  - `@ModelActor public actor TaxStore`.
  - `struct YearFacts: Sendable`, `struct EntryDraft: Sendable`,
    `struct PreferencesSnapshot: Sendable`, `struct DependentDraft: Sendable`.
  - Writes: `saveYearFacts(_:for:)`, `save(_ draft: EntryDraft) -> UUID`,
    `softDeleteEntry(id:)`, `restoreEntry(id:)`, `save(_ draft: DependentDraft) -> UUID`,
    `softDeleteDependent(id:)`, `savePreferences(_:)`.
  - Reads: `entryDrafts(forYear:)`, `dependentDrafts()`, `yearFacts(for:)`,
    `preferences()`, `liveYears()`.
  - Test seam: `useClock(_:)`.

**Everything crossing the actor boundary is a value type.** `@Model` classes are not
`Sendable` and must not escape `TaxStore`. So the store takes `EntryDraft` in and hands
`EntryDraft` out; it never returns a `ReliefEntry`. This is not a concession to the
compiler — it is the reason "no view touches `modelContext`" can be enforced structurally
rather than by convention, because a view has nothing to touch. Spec §5 makes the
discipline structural for exactly this reason.

**The clock is injected.** `updatedAt` is the field CloudKit's newest-write-wins conflict
resolution and the reconciliation sweep both key off. A test that cannot control it
cannot assert which of two rows survives, so `useClock(_:)` exists and every test that
cares uses it. Production never calls it and gets `Date.init`.

**`needsDocument` and `dedupeKey` are left at their defaults by this task.** Both are
derived from the rulebook, which the store does not yet load. Task 5 adds them and
backfills. Until then they are `false` and `""`, which is correct-but-uninformative
rather than wrong.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxDataTests/TaxStoreTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
import TaxKit
@testable import TaxData

/// Builders shared by the store, dedupe and reconciliation suites.
enum StoreFixture {

    static let epoch = Date(timeIntervalSince1970: 1_750_000_000)   // 2025-06-15 UTC

    static func store(at instant: Date = epoch) async throws -> TaxStore {
        let container = try TaxContainer.make(.inMemory)
        let store = TaxStore(modelContainer: container)
        await store.useClock { instant }
        return store
    }

    static func entry(_ code: String,
                      _ ringgit: Decimal,
                      year: Int = 2025,
                      vendor: String = "Popular Bookstore",
                      spentOn: Date? = Date(timeIntervalSince1970: 1_740_000_000)) -> EntryDraft {
        EntryDraft(year: year,
                   code: ReliefCode(code),
                   amount: Money(ringgit: ringgit),
                   vendor: vendor,
                   spentOn: spentOn)
    }
}

@Suite("TaxStore") struct TaxStoreTests {

    @Test("saving an entry creates its year on demand")
    func savingCreatesTheYear() async throws {
        let store = try await StoreFixture.store()
        _ = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))

        let years = try await store.liveYears()
        #expect(years == [2025])
        let drafts = try await store.entryDrafts(forYear: 2025)
        #expect(drafts.count == 1)
        #expect(drafts.first?.code == ReliefCode("LIFESTYLE"))
        #expect(drafts.first?.amount == Money(ringgit: 1_820))
    }

    @Test("every write stamps updatedAt from the injected clock")
    func writesAreStamped() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))

        var drafts = try await store.entryDrafts(forYear: 2025)
        #expect(drafts.first?.updatedAt == StoreFixture.epoch)

        let later = StoreFixture.epoch.addingTimeInterval(3_600)
        await store.useClock { later }
        var edited = try #require(drafts.first)
        edited.amount = Money(ringgit: 2_000)
        _ = try await store.save(edited)

        drafts = try await store.entryDrafts(forYear: 2025)
        #expect(drafts.count == 1, "editing must update in place, not insert a second row")
        #expect(drafts.first?.id == id)
        #expect(drafts.first?.amount == Money(ringgit: 2_000))
        #expect(drafts.first?.updatedAt == later)
    }

    @Test("deleting is soft and reversible")
    func softDeleteAndRestore() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))

        try await store.softDeleteEntry(id: id)
        #expect(try await store.entryDrafts(forYear: 2025).isEmpty)

        // Spec §11.6: every destructive action is undoable. A hard delete would make the
        // undo toast a lie, and would let a delete on one device beat a concurrent edit
        // on another into permanent data loss.
        try await store.restoreEntry(id: id)
        let drafts = try await store.entryDrafts(forYear: 2025)
        #expect(drafts.count == 1)
        #expect(drafts.first?.id == id)
    }

    @Test("deleting a missing entry is a no-op, not a throw")
    func deletingMissingIsNoOp() async throws {
        let store = try await StoreFixture.store()
        // The same delete can arrive twice — an undo toast tapped as a sync lands. It
        // must be idempotent, or the second one crashes a screen the user is looking at.
        try await store.softDeleteEntry(id: UUID())
        #expect(try await store.liveYears().isEmpty)
    }

    @Test("year facts round-trip and stamp the year")
    func yearFacts() async throws {
        let store = try await StoreFixture.store()
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        facts.maritalStatus = .married
        facts.spouseHasIncome = false
        facts.assessmentType = .separate
        facts.employmentType = .privateSector
        facts.gender = .female
        facts.propertyPrice = Money(ringgit: 480_000)
        try await store.saveYearFacts(facts, for: 2025)

        let read = try await store.yearFacts(for: 2025)
        #expect(read.grossIncome == Money(ringgit: 128_000))
        #expect(read.maritalStatus == .married)
        #expect(read.spouseHasIncome == false)
        #expect(read.propertyPrice == Money(ringgit: 480_000))
    }

    @Test("an unknown year reads as empty facts rather than throwing")
    func unknownYearIsEmpty() async throws {
        let store = try await StoreFixture.store()
        let facts = try await store.yearFacts(for: 2023)
        // Empty, not absent: every optional means "not yet known", which the engine
        // renders as a prompt. Throwing here would make the Home screen an error screen
        // for anyone who switches to a year they have not filled in.
        #expect(facts.grossIncome == nil)
        #expect(facts.maritalStatus == nil)
    }

    @Test("dependents round-trip with their per-year statuses")
    func dependents() async throws {
        let store = try await StoreFixture.store()
        var draft = DependentDraft(name: "Farah")
        draft.kind = .child
        draft.dateOfBirth = Date(timeIntervalSince1970: 1_253_491_200)   // 2009-09-21
        draft.yearStatuses = [DependentYearStatus(year: 2025,
                                                  educationLevel: .preTertiary,
                                                  claimPercentage: 50,
                                                  isFullTime: true)]
        let id = try await store.save(draft)

        let all = try await store.dependentDrafts()
        #expect(all.count == 1)
        #expect(all.first?.id == id)
        #expect(all.first?.yearStatuses.first?.claimPercentage == 50)
    }

    @Test("two preference rows collapse to the newest")
    func preferencesCollisionResolves() async throws {
        let store = try await StoreFixture.store()

        var first = PreferencesSnapshot()
        first.incomeModuleEnabled = false
        try await store.savePreferences(first)

        // Simulate the offline-first-launch collision: a second row arrives from another
        // device with a later stamp. CloudKit cannot enforce a singleton, so the store
        // resolves it by the same rule the sweep uses — newest updatedAt wins.
        let later = StoreFixture.epoch.addingTimeInterval(60)
        await store.useClock { later }
        try await store.insertDuplicatePreferencesForTesting(incomeModuleEnabled: true)

        let resolved = try await store.preferences()
        #expect(resolved.incomeModuleEnabled == true)
        #expect(try await store.livePreferenceRowCount() == 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TaxStore`
Expected: FAIL — "cannot find 'TaxStore' in scope".

- [ ] **Step 3: Write the drafts and the write path**

Create `Sources/TaxData/Store/TaxStore.swift`:

```swift
import Foundation
import SwiftData
import TaxKit

/// One Year of Assessment's income and household facts, as a value.
public struct YearFacts: Hashable, Sendable {
    public var grossIncome: Money?
    public var epf: Money?
    public var socso: Money?
    public var maritalStatus: MaritalStatus?
    public var spouseHasIncome: Bool?
    public var assessmentType: AssessmentType?
    public var employmentType: EmploymentType?
    public var gender: Gender?
    public var propertyPrice: Money?
    public var selfIsDisabled: Bool?
    public var spouseIsDisabled: Bool?

    public init() {}
}

/// One entry, as a value. `id == nil` creates; a known `id` updates in place.
public struct EntryDraft: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var year: Int
    public var code: ReliefCode
    public var amount: Money
    public var claimant: Claimant
    public var dependentID: UUID?
    public var vendor: String
    public var spentOn: Date?
    public var note: String
    /// Read-only for callers; the store owns it.
    public internal(set) var updatedAt: Date
    public internal(set) var needsDocument: Bool
    public internal(set) var documentKinds: Set<DocumentKind>

    public init(id: UUID = UUID(),
                year: Int,
                code: ReliefCode,
                amount: Money,
                claimant: Claimant = .individual,
                dependentID: UUID? = nil,
                vendor: String = "",
                spentOn: Date? = nil,
                note: String = "") {
        self.id = id
        self.year = year
        self.code = code
        self.amount = amount
        self.claimant = claimant
        self.dependentID = dependentID
        self.vendor = vendor
        self.spentOn = spentOn
        self.note = note
        self.updatedAt = .distantPast
        self.needsDocument = false
        self.documentKinds = []
    }
}

public struct DependentDraft: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: DependentKind
    public var dateOfBirth: Date?
    /// `nil` is "not asked yet", which the engine turns into a prompt. Never default
    /// this to `false`.
    public var isDisabled: Bool?
    public var yearStatuses: [DependentYearStatus]

    public init(id: UUID = UUID(),
                name: String = "",
                kind: DependentKind = .child,
                dateOfBirth: Date? = nil,
                isDisabled: Bool? = nil,
                yearStatuses: [DependentYearStatus] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.dateOfBirth = dateOfBirth
        self.isDisabled = isDisabled
        self.yearStatuses = yearStatuses
    }
}

public struct PreferencesSnapshot: Hashable, Sendable {
    public var accentName: String
    public var assistantEnabled: Bool
    public var captureQuality: CaptureQuality
    public var incomeModuleEnabled: Bool
    public var hasCompletedOnboarding: Bool
    public var lastViewedYear: Int

    public init(accentName: String = "default",
                assistantEnabled: Bool = true,
                captureQuality: CaptureQuality = .balanced,
                incomeModuleEnabled: Bool = false,
                hasCompletedOnboarding: Bool = false,
                lastViewedYear: Int = 0) {
        self.accentName = accentName
        self.assistantEnabled = assistantEnabled
        self.captureQuality = captureQuality
        self.incomeModuleEnabled = incomeModuleEnabled
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.lastViewedYear = lastViewedYear
    }
}

/// The only thing in the app allowed to write.
///
/// Every parameter and every return value is a `Sendable` value type, so a `@Model`
/// object cannot escape this actor. That is what makes "no view touches `modelContext`"
/// a structural property rather than a rule someone has to remember: a view has nothing
/// to touch. Spec §5.
@ModelActor
public actor TaxStore {

    /// Injected so tests can control `updatedAt`, which is what CloudKit's
    /// newest-write-wins and the reconciliation sweep both key off.
    private var now: @Sendable () -> Date = { Date() }

    public func useClock(_ clock: @escaping @Sendable () -> Date) {
        now = clock
    }

    // MARK: - Years

    public func saveYearFacts(_ facts: YearFacts, for year: Int) throws {
        let stamp = now()
        let row = try fetchOrCreateYear(year)
        row.grossIncome = facts.grossIncome
        row.epf = facts.epf
        row.socso = facts.socso
        row.maritalStatus = facts.maritalStatus
        row.spouseHasIncome = facts.spouseHasIncome
        row.assessmentType = facts.assessmentType
        row.employmentType = facts.employmentType
        row.gender = facts.gender
        row.propertyPriceSen = facts.propertyPrice?.sen
        row.selfIsDisabled = facts.selfIsDisabled
        row.spouseIsDisabled = facts.spouseIsDisabled
        row.updatedAt = stamp
        try modelContext.save()
    }

    // MARK: - Entries

    @discardableResult
    public func save(_ draft: EntryDraft) throws -> UUID {
        let stamp = now()
        let year = try fetchOrCreateYear(draft.year)

        let identifier = draft.id
        let existing = try modelContext.fetch(
            FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == identifier })
        ).first

        let row = existing ?? ReliefEntry(id: identifier)
        if existing == nil { modelContext.insert(row) }

        row.reliefCode = draft.code
        row.amount = draft.amount
        row.claimant = draft.claimant
        row.dependentID = draft.dependentID
        row.vendor = draft.vendor
        row.spentOn = draft.spentOn
        row.note = draft.note
        row.taxYear = year
        row.deletedAt = nil
        row.updatedAt = stamp
        year.updatedAt = stamp

        try modelContext.save()
        return identifier
    }

    /// Idempotent: deleting an id that is absent or already deleted is a no-op. The same
    /// delete can arrive twice — an undo toast tapped as a sync lands — and the second
    /// one must not crash a screen the user is looking at.
    public func softDeleteEntry(id: UUID) throws {
        guard let row = try entryRow(id) else { return }
        row.deletedAt = now()
        row.updatedAt = now()
        try modelContext.save()
    }

    public func restoreEntry(id: UUID) throws {
        guard let row = try entryRow(id) else { return }
        row.deletedAt = nil
        row.mergedInto = nil
        row.updatedAt = now()
        try modelContext.save()
    }

    // MARK: - Dependents

    @discardableResult
    public func save(_ draft: DependentDraft) throws -> UUID {
        let stamp = now()
        let identifier = draft.id
        let existing = try modelContext.fetch(
            FetchDescriptor<Dependent>(predicate: #Predicate { $0.id == identifier })
        ).first

        let row = existing ?? Dependent(id: identifier)
        if existing == nil { modelContext.insert(row) }

        row.name = draft.name
        row.kind = draft.kind
        row.dateOfBirth = draft.dateOfBirth
        row.isDisabled = draft.isDisabled
        row.yearStatuses = draft.yearStatuses
        row.deletedAt = nil
        row.updatedAt = stamp

        try modelContext.save()
        return identifier
    }

    public func softDeleteDependent(id: UUID) throws {
        let descriptor = FetchDescriptor<Dependent>(predicate: #Predicate { $0.id == id })
        guard let row = try modelContext.fetch(descriptor).first else { return }
        row.deletedAt = now()
        row.updatedAt = now()
        try modelContext.save()
    }

    // MARK: - Preferences

    public func savePreferences(_ snapshot: PreferencesSnapshot) throws {
        let row = try resolvedPreferencesRow() ?? {
            let fresh = UserPreferences()
            modelContext.insert(fresh)
            return fresh
        }()
        row.accentName = snapshot.accentName
        row.assistantEnabled = snapshot.assistantEnabled
        row.captureQuality = snapshot.captureQuality
        row.incomeModuleEnabled = snapshot.incomeModuleEnabled
        row.hasCompletedOnboarding = snapshot.hasCompletedOnboarding
        row.lastViewedYear = snapshot.lastViewedYear
        row.updatedAt = now()
        try modelContext.save()
    }

    // MARK: - Internals

    private func fetchOrCreateYear(_ year: Int) throws -> TaxYear {
        let descriptor = FetchDescriptor<TaxYear>(
            predicate: #Predicate { $0.year == year && $0.deletedAt == nil })
        if let existing = try modelContext.fetch(descriptor).first { return existing }
        let fresh = TaxYear(year: year)
        fresh.updatedAt = now()
        modelContext.insert(fresh)
        return fresh
    }

    private func entryRow(_ id: UUID) throws -> ReliefEntry? {
        try modelContext.fetch(
            FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == id })
        ).first
    }

    /// CloudKit cannot enforce a singleton, so two devices first launching offline each
    /// create a preferences row. Keep the newest, soft-delete the rest — the same rule
    /// the reconciliation sweep applies to entries, so both converge the same way.
    private func resolvedPreferencesRow() throws -> UserPreferences? {
        let live = try modelContext
            .fetch(FetchDescriptor<UserPreferences>())
            .filter(\.isLive)
            .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
        guard let survivor = live.first else { return nil }
        // A losing preferences row carries no `mergedInto`: there is nothing to audit
        // in a settings row, only a value to keep.
        for loser in live.dropFirst() { loser.deletedAt = now() }
        return survivor
    }
}
```

- [ ] **Step 4: Write the read side**

Create `Sources/TaxData/Store/TaxStore+Reads.swift`:

```swift
import Foundation
import SwiftData
import TaxKit

extension TaxStore {

    /// Years that have any live row, ascending. Drives the year switcher.
    public func liveYears() throws -> [Int] {
        let years = try modelContext
            .fetch(FetchDescriptor<TaxYear>(predicate: #Predicate { $0.deletedAt == nil }))
            .map(\.year)
        return Array(Set(years)).sorted()
    }

    public func yearFacts(for year: Int) throws -> YearFacts {
        let descriptor = FetchDescriptor<TaxYear>(
            predicate: #Predicate { $0.year == year && $0.deletedAt == nil })
        guard let row = try modelContext.fetch(descriptor).first else { return YearFacts() }

        var facts = YearFacts()
        facts.grossIncome = row.grossIncome
        facts.epf = row.epf
        facts.socso = row.socso
        facts.maritalStatus = row.maritalStatus
        facts.spouseHasIncome = row.spouseHasIncome
        facts.assessmentType = row.assessmentType
        facts.employmentType = row.employmentType
        facts.gender = row.gender
        facts.propertyPrice = row.propertyPriceSen.map(Money.init(sen:))
        facts.selfIsDisabled = row.selfIsDisabled
        facts.spouseIsDisabled = row.spouseIsDisabled
        return facts
    }

    /// Live entries for a year, ordered deterministically by id so two devices agree.
    public func entryDrafts(forYear year: Int) throws -> [EntryDraft] {
        let descriptor = FetchDescriptor<ReliefEntry>(
            predicate: #Predicate { $0.taxYear?.year == year && $0.deletedAt == nil })
        return try modelContext.fetch(descriptor)
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map(Self.draft(from:))
    }

    public func dependentDrafts() throws -> [DependentDraft] {
        try modelContext
            .fetch(FetchDescriptor<Dependent>(predicate: #Predicate { $0.deletedAt == nil }))
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { row in
                DependentDraft(id: row.id,
                               name: row.name,
                               kind: row.kind,
                               dateOfBirth: row.dateOfBirth,
                               isDisabled: row.isDisabled,
                               yearStatuses: row.yearStatuses.sorted { $0.year < $1.year })
            }
    }

    public func preferences() throws -> PreferencesSnapshot {
        guard let row = try resolvedPreferencesRowForReading() else { return PreferencesSnapshot() }
        return PreferencesSnapshot(accentName: row.accentName,
                                   assistantEnabled: row.assistantEnabled,
                                   captureQuality: row.captureQuality,
                                   incomeModuleEnabled: row.incomeModuleEnabled,
                                   hasCompletedOnboarding: row.hasCompletedOnboarding,
                                   lastViewedYear: row.lastViewedYear)
    }

    static func draft(from row: ReliefEntry) -> EntryDraft {
        var draft = EntryDraft(id: row.id,
                               year: row.taxYear?.year ?? 0,
                               code: row.reliefCode,
                               amount: row.amount,
                               claimant: row.claimant,
                               dependentID: row.dependentID,
                               vendor: row.vendor,
                               spentOn: row.spentOn,
                               note: row.note)
        draft.updatedAt = row.updatedAt
        draft.needsDocument = row.needsDocument
        draft.documentKinds = row.documentKinds
        return draft
    }

    private func resolvedPreferencesRowForReading() throws -> UserPreferences? {
        let live = try modelContext
            .fetch(FetchDescriptor<UserPreferences>())
            .filter(\.isLive)
            .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
        guard let survivor = live.first else { return nil }
        for loser in live.dropFirst() { loser.deletedAt = now() }
        if live.count > 1 { try modelContext.save() }
        return survivor
    }
}

// MARK: - Test-only seams

extension TaxStore {

    /// Creates the collision CloudKit can produce but a single device cannot: a second
    /// live preferences row. Only the tests call this.
    func insertDuplicatePreferencesForTesting(incomeModuleEnabled: Bool) throws {
        let row = UserPreferences()
        row.incomeModuleEnabled = incomeModuleEnabled
        row.updatedAt = now()
        modelContext.insert(row)
        try modelContext.save()
    }

    func livePreferenceRowCount() throws -> Int {
        try modelContext.fetch(FetchDescriptor<UserPreferences>()).filter(\.isLive).count
    }
}
```

**Note on `now()` in `TaxStore+Reads.swift`:** `now` is `private` in `TaxStore.swift`.
Change it to `internal` (drop the `private`) so the extension in the same module can read
it. Keep `useClock` as the only mutator.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter TaxStore`
Expected: PASS — 8 tests.

**If `#Predicate { $0.taxYear?.year == year }` fails to compile or returns nothing**,
SwiftData cannot always push an optional-relationship traversal into the store. Fall back
to fetching all live entries and filtering in Swift:

```swift
        return try modelContext
            .fetch(FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.deletedAt == nil }))
            .filter { $0.taxYear?.year == year }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map(Self.draft(from:))
```

Record which one you used in the ledger — it matters for the performance budget in spec
§11.4, and Task 8's persona test is the place it would first show up.

- [ ] **Step 6: Run the whole suite and commit**

Run: `swift test`
Expected: PASS, no regressions.

```bash
git add Sources/TaxData Tests/TaxDataTests
git commit -m "feat: add TaxStore as the only write path, with value types at the boundary"
```

---

### Task 5: `dedupeKey`, `contentHash` and the `needsDocument` cache

**Files:**
- Create: `Sources/TaxData/Dedupe/Normalisation.swift`
- Create: `Sources/TaxData/Dedupe/DedupeKey.swift`
- Modify: `Sources/TaxData/Store/TaxStore.swift` (stamp the derived fields on write)
- Test: `Tests/TaxDataTests/DedupeTests.swift`

**Interfaces:**
- Consumes: `ReliefEntry`, `TaxStore` from Task 4; `RuleSetLoading`, `ReliefCode`,
  `DocumentKind` from `TaxKit`.
- Produces:
  - `enum Normalisation { static func vendor(_:) -> String; static func day(_:) -> String }`
  - `enum DedupeKey { static func entry(code:amountSen:day:vendor:) -> String;
    static func content(_ data: Data) -> String }`
  - `TaxStore.useRuleSetLoader(_:)`, `TaxStore.recomputeAllDedupeKeys()`.

**Why the key is computed, not chosen.** CloudKit forbids unique constraints, so
duplicates cannot be prevented — spec §6 makes them *detectable and collapsible* instead.
The key is SHA-256 over `(reliefCode, year, amount.sen, day, normalised vendor, claimant,
dependentID)`.

**The key must carry everything that distinguishes one claim from another, not merely what
distinguishes one receipt from another.** Spec §6.1 lists four components; four is not
enough, and Task 6's review found why. `Normalisation.day(nil)` is `""` and `spentOn`
defaults to `nil`, so an undated recurring claim — SSPN, LIFE_INSURANCE, a LIFESTYLE entry
typed without a receipt date — logged in YA2024 and again in YA2025 would hash identically,
and the sweep would soft-delete the earlier year's row. A whole year's claim would vanish
from the user's records. Year, claimant and `dependentID` are therefore part of the key: a
receipt belongs to exactly one year, one claimant and at most one dependent. Without
`dependentID`, two children's identical claims in one year collapse into one.

Every component must also be canonical, or two devices produce different keys for the same
receipt and the sweep in Task 6 never converges:

- **Vendor** is folded for case and diacritics, then reduced to alphanumeric words joined
  by single spaces. `"Guardian Health–KL"`, `"guardian  health kl"` and `"GUARDIAN
  HEALTH  KL"` are one vendor.
- **Day** is formatted `yyyy-MM-dd` on a `.gregorian` calendar in `Asia/Kuala_Lumpur`,
  with a POSIX locale. Not the device's zone: a receipt logged at 05:20 on 20 February in
  Kuala Lumpur is 19 February in UTC, and a phone abroad would otherwise disagree with
  the phone at home about the same purchase.
- **A nil date contributes the empty string.** Two dateless entries for the same vendor
  and amount then collide deliberately — that is very likely the same receipt entered
  twice, which is precisely what the sweep should offer to merge.

**`needsDocument` is recomputed here** because it needs the rulebook. The store gets an
injectable `RuleSetLoading` defaulting to `BundledRuleSetLoader()`; a year with no
shipped ruleset leaves the flag false rather than throwing, because a user browsing
YA2026 before its rules exist should see their entries, not an error.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxDataTests/DedupeTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Normalisation") struct NormalisationTests {

    @Test("vendor folding collapses case, diacritics and punctuation")
    func vendorFolding() {
        #expect(Normalisation.vendor("Guardian Health–KL") == "guardian health kl")
        #expect(Normalisation.vendor("guardian  health kl") == "guardian health kl")
        #expect(Normalisation.vendor("GUARDIAN HEALTH  KL") == "guardian health kl")
        #expect(Normalisation.vendor("  Kedai Buku Popular  ") == "kedai buku popular")
        #expect(Normalisation.vendor("Café Société") == "cafe societe")
        #expect(Normalisation.vendor("") == "")
        #expect(Normalisation.vendor("!!!") == "")
    }

    @Test("a day is resolved in Kuala Lumpur, not UTC")
    func dayIsKualaLumpur() {
        // 1_740_000_000 is 2025-02-19 21:20 UTC, which is 2025-02-20 05:20 in KL.
        // A phone abroad must agree with the phone at home about which day this was, or
        // the two produce different dedupe keys for one receipt and never converge.
        let instant = Date(timeIntervalSince1970: 1_740_000_000)
        #expect(Normalisation.day(instant) == "2025-02-20")
        #expect(Normalisation.day(nil) == "")
    }
}

@Suite("Dedupe keys") struct DedupeTests {

    @Test("the same receipt entered twice produces one key")
    func sameReceiptSameKey() async throws {
        let store = try await StoreFixture.store()
        var second = StoreFixture.entry("MEDICAL_CHECKUP", 900, vendor: "guardian  health kl")
        second.id = UUID()
        let firstID = try await store.save(
            StoreFixture.entry("MEDICAL_CHECKUP", 900, vendor: "Guardian Health–KL"))
        let secondID = try await store.save(second)

        let firstKey = try await store.dedupeKey(forEntry: firstID)
        let secondKey = try await store.dedupeKey(forEntry: secondID)
        #expect(firstKey == secondKey)
        #expect(firstKey.count == 64, "SHA-256 rendered as lowercase hex")
    }

    @Test("a different amount produces a different key")
    func amountChangesKey() async throws {
        let store = try await StoreFixture.store()
        let a = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))
        var other = StoreFixture.entry("LIFESTYLE", 1_821)
        other.id = UUID()
        let b = try await store.save(other)

        let keyA = try await store.dedupeKey(forEntry: a)
        let keyB = try await store.dedupeKey(forEntry: b)
        #expect(keyA != keyB)
    }

    @Test("a different relief code produces a different key")
    func codeChangesKey() {
        let a = Self.key(code: "LIFESTYLE")
        let b = Self.key(code: "LIFESTYLE_SPORTS")
        #expect(a != b)
    }

    /// One builder so each test varies exactly one component.
    static func key(code: String = "LIFESTYLE",
                    year: Int = 2025,
                    amountSen: Int = 182_000,
                    day: String = "2025-02-20",
                    vendor: String = "popular",
                    claimant: Claimant = .individual,
                    dependentID: UUID? = nil) -> String {
        DedupeKey.entry(code: ReliefCode(code), year: year, amountSen: amountSen,
                        day: day, vendor: vendor, claimant: claimant,
                        dependentID: dependentID)
    }

    @Test("the same undated claim in two years is two claims, not one")
    func yearSeparatesKeys() {
        // The regression test for a Critical found in Task 6's review. day("") for an
        // undated entry plus a recurring claim like SSPN meant YA2024 and YA2025 hashed
        // identically, and the sweep soft-deleted the earlier year's row — a whole year's
        // claim gone from the user's records.
        #expect(Self.key(year: 2024, day: "") != Self.key(year: 2025, day: ""))
    }

    @Test("two dependents' identical claims are two claims")
    func dependentSeparatesKeys() {
        let farah = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let danish = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        #expect(Self.key(dependentID: farah) != Self.key(dependentID: danish))
        #expect(Self.key(dependentID: nil) != Self.key(dependentID: farah))
    }

    @Test("the same spend claimed for a different person is a different claim")
    func claimantSeparatesKeys() {
        #expect(Self.key(claimant: .individual) != Self.key(claimant: .spouse))
    }

    @Test("an undated recurring claim in two years survives the sweep")
    func recurringClaimAcrossYearsIsNotCollapsed() async throws {
        let store = try await StoreFixture.store()
        for year in [2024, 2025] {
            var draft = StoreFixture.entry("SSPN", 3_000, year: year, spentOn: nil)
            draft.id = UUID()
            draft.vendor = ""
            _ = try await store.save(draft)
        }

        #expect(try await store.reconcile().isEmpty)
        // Row counts, not key inequality: this is the assertion that would have caught
        // the Critical.
        #expect(try await store.entryDrafts(forYear: 2024).count == 1)
        #expect(try await store.entryDrafts(forYear: 2025).count == 1)
    }

    @Test("components cannot be smuggled across the encoding")
    func componentsCannotBeSmuggledAcrossTheEncoding() {
        // `ReliefCode` performs no character validation and `reliefCodeRaw` is written
        // directly by sync, so a code containing the delimiter is reachable from a synced
        // record rather than hypothetical.
        //
        // These two both flatten to "A|1|23|D|V" under the old pipe-joined scheme and so
        // hashed identically. Note the collision has to cascade across all four fields:
        // amountSen renders as bare digits with no separators of its own, so a simple
        // code-versus-vendor swap is not reachable on its own.
        let a = DedupeKey.entry(code: ReliefCode("A|1"), amountSen: 23, day: "D", vendor: "V")
        let b = DedupeKey.entry(code: ReliefCode("A"), amountSen: 1, day: "23", vendor: "D|V")
        #expect(a != b)
    }

    @Test("editing an entry recomputes its key")
    func editRecomputesKey() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))
        let before = try await store.dedupeKey(forEntry: id)

        var edited = try #require(try await store.entryDrafts(forYear: 2025).first)
        edited.amount = Money(ringgit: 2_000)
        _ = try await store.save(edited)

        let after = try await store.dedupeKey(forEntry: id)
        #expect(before != after, "a stale key would hide a duplicate the edit just created")
    }

    @Test("content hashing is stable and sensitive")
    func contentHash() {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        #expect(DedupeKey.content(bytes) == DedupeKey.content(bytes))
        #expect(DedupeKey.content(bytes) != DedupeKey.content(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x11])))
        #expect(DedupeKey.content(bytes).count == 64)
    }

    @Test("needsDocument is true when a required document is absent")
    func needsDocumentReflectsTheRulebook() async throws {
        let store = try await StoreFixture.store()
        // LIFE_INSURANCE requires an insurance statement in the YA2025 rulebook and this
        // entry has no documents attached at all.
        let id = try await store.save(StoreFixture.entry("LIFE_INSURANCE", 2_100))
        let draft = try #require(try await store.entryDrafts(forYear: 2025).first { $0.id == id })
        #expect(draft.needsDocument == true)
    }

    @Test("an entry in a year with no shipped rulebook is not flagged")
    func unknownYearDoesNotFlag() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(StoreFixture.entry("LIFE_INSURANCE", 2_100, year: 2019))
        let draft = try #require(try await store.entryDrafts(forYear: 2019).first { $0.id == id })
        // Browsing a year whose rules the app does not ship must show the entries, not
        // an amber warning the app has no basis for.
        #expect(draft.needsDocument == false)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter Dedupe`
Expected: FAIL — "cannot find 'Normalisation' in scope".

- [ ] **Step 3: Write the normalisation and the key**

Create `Sources/TaxData/Dedupe/Normalisation.swift`:

```swift
import Foundation

/// Canonical forms for the fields that go into a dedupe key.
///
/// Every one of these must be device-independent. Two phones that disagree about the
/// spelling of a vendor or the day of a purchase produce two keys for one receipt, and
/// the reconciliation sweep then never converges — it would keep both rows forever and
/// the user would see the duplicate the sweep exists to remove.
public enum Normalisation {

    /// Case- and diacritic-folded, reduced to alphanumeric words joined by single spaces.
    public static func vendor(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// `yyyy-MM-dd` in Kuala Lumpur, or `""` for an unknown date.
    ///
    /// Fixed zone, fixed calendar, POSIX locale: the device's own settings must not
    /// change the answer. A purchase at 05:20 on 20 February in KL is still 19 February
    /// in UTC, and the two must not hash differently.
    public static func day(_ instant: Date?) -> String {
        guard let instant else { return "" }
        return dayFormatter.string(from: instant)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
```

Create `Sources/TaxData/Dedupe/DedupeKey.swift`:

```swift
import Foundation
import CryptoKit
import TaxKit

/// The keys that make duplicates detectable, since CloudKit will not let them be
/// prevented. Spec §6.
public enum DedupeKey {

    /// SHA-256 over the identifying tuple, lowercase hex.
    ///
    /// Components are length-prefixed rather than merely delimited, which makes the
    /// encoding injective for ANY component content. A plain `|` separator would rest on
    /// the assumption that no component can contain one — and nothing enforces that:
    /// `ReliefCode` is a bare `RawRepresentable` with no character validation, and
    /// `reliefCodeRaw` is a plain `String` that CloudKit sync writes into directly. A
    /// record from a future or corrupted build could carry a `|` and defeat exactly the
    /// guarantee this type exists to provide.
    public static func entry(code: ReliefCode,
                             year: Int,
                             amountSen: Int,
                             day: String,
                             vendor: String,
                             claimant: Claimant,
                             dependentID: UUID?) -> String {
        hex(of: encode([code.rawValue,
                        String(year),
                        String(amountSen),
                        day,
                        vendor,
                        claimant.rawValue,
                        dependentID?.uuidString ?? ""]))
    }

    /// `["ab", "c"]` becomes `"2:ab|1:c"`. The byte count preceding each component makes
    /// the boundary unambiguous no matter what the component contains.
    private static func encode(_ components: [String]) -> String {
        components
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
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
```

- [ ] **Step 4: Stamp the derived fields in `TaxStore`**

Modify `Sources/TaxData/Store/TaxStore.swift`.

Add beside the clock:

```swift
    /// Injectable so a test can pin a rulebook. Production uses the bundled one.
    private var ruleSetLoader: any RuleSetLoading = BundledRuleSetLoader()

    public func useRuleSetLoader(_ loader: any RuleSetLoading) {
        ruleSetLoader = loader
    }
```

In `save(_ draft: EntryDraft)`, replace the two lines `row.updatedAt = stamp` /
`year.updatedAt = stamp` with:

```swift
        row.updatedAt = stamp
        year.updatedAt = stamp
        refreshDerivedFields(on: row)
```

Add to the internals section:

```swift
    /// The two fields the store owns rather than the caller: a key that must never go
    /// stale, and a flag `#Predicate` needs because it cannot call the engine.
    private func refreshDerivedFields(on row: ReliefEntry) {
        row.dedupeKey = DedupeKey.entry(code: row.reliefCode,
                                        year: row.taxYear?.year ?? 0,
                                        amountSen: row.amountSen,
                                        day: Normalisation.day(row.spentOn),
                                        vendor: Normalisation.vendor(row.vendor),
                                        claimant: row.claimant,
                                        dependentID: row.dependentID)
        row.needsDocument = missingRequiredDocument(for: row)
    }

    /// A year whose rules this build does not ship yields `false`, not a warning: the
    /// app has no basis to claim a document is missing against rules it cannot read.
    private func missingRequiredDocument(for row: ReliefEntry) -> Bool {
        guard let year = row.taxYear?.year,
              let ruleSet = try? ruleSetLoader.ruleSet(for: year),
              let rule = ruleSet.relief(for: row.reliefCode) else { return false }
        return !Set(rule.requiredDocuments).isSubset(of: row.documentKinds)
    }

    /// Rewrites every live entry's key. Needed after a change to the normalisation rules
    /// or to the key's components, which would otherwise leave old rows unmatchable
    /// against new ones and silently break the sweep.
    public func recomputeAllDedupeKeys() throws {
        let rows = try modelContext
            .fetch(FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.deletedAt == nil }))
        for row in rows { refreshDerivedFields(on: row) }
        try modelContext.save()
    }
```

Add a read seam to `Sources/TaxData/Store/TaxStore+Reads.swift`:

```swift
    /// The stored key for one entry. Exposed for the dedupe tests and for the merge UI.
    public func dedupeKey(forEntry id: UUID) throws -> String {
        let descriptor = FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(descriptor).first?.dedupeKey ?? ""
    }
```

`RuleSet.relief(for:)` and `ReliefRule.requiredDocuments` are both as Plan 1 shipped
them; `relief(for:)` searches `allReliefs`, so a sub-limit code such as `MEDICAL_CHECKUP`
resolves as readily as a top-level one.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "Dedupe|Normalisation"`
Expected: PASS — 10 tests in 2 suites.

- [ ] **Step 6: Commit**

```bash
git add Sources/TaxData Tests/TaxDataTests
git commit -m "feat: compute dedupe keys, content hashes and the needs-document cache"
```

---

### Task 6: The reconciliation sweep

**Files:**
- Create: `Sources/TaxData/Dedupe/Reconciliation.swift`
- Test: `Tests/TaxDataTests/ReconciliationTests.swift`

**Interfaces:**
- Consumes: `ReliefEntry`, `TaxStore`, `DedupeKey` from Tasks 4–5.
- Produces:
  - `struct MergeReport: Hashable, Sendable` — `dedupeKey`, `survivorID`, `mergedIDs`.
  - `TaxStore.reconcile() throws -> [MergeReport]`.
  - `TaxStore.unmerge(entryID:) throws` — reverses one merge.
  - `TaxStore.reconcileYears() throws -> Int` — collapses duplicate `TaxYear` rows,
    returning how many were merged away. Called by `reconcile()` before entries.

**Added to this task's scope by a Task 4 ruling.** Task 4's review found that two devices
first launching offline produce two live `TaxYear` rows for the same year, and that
`yearFacts` picked one arbitrarily. Task 4 made the *selection* deterministic, which stops
the nondeterministic-income bug; collapsing the duplicate belongs here, with the rest of
duplicate handling.

`reconcileYears()` keeps the newest row (ties on `id.uuidString`, the same total order as
everything else here), re-points every loser's entries at the survivor, and soft-deletes
the losers. **Facts merge by filling gaps, never by overwriting:** for each optional fact,
the survivor keeps its own value and adopts the loser's only where its own is `nil`. A
`nil` means "not answered yet" throughout this app, so filling a gap cannot lose an
answer, and refusing to overwrite means a newer device's answer always wins. Discarding
the loser's facts outright would silently throw away income the user entered on their
other phone.

**The sweep must be deterministic, and that is the whole design.** Spec §6.4 says every
device runs it independently and they all converge. Nothing coordinates them, so the
survivor must be a pure function of the rows. Newest `updatedAt` wins; ties break on
`id.uuidString`. Without the tie-break two devices can pick different survivors from the
same data — and because the losers are soft-deleted rather than removed, they would then
resurrect each other's rows on the next sync and the duplicate would never go away. This
is the same class of bug Plan 1 found in the counterfactual's unstable sort, and the fix
is the same: a total order, not merely a sort key.

**Losers are soft-deleted with `mergedInto`, never removed.** The merge is then auditable
and reversible — spec §6.4 requires both. `unmerge` exists so a user who disagrees can
get their row back; an irreversible automatic merge of someone's tax records is not
something this app should be able to do.

**Rows with an empty `dedupeKey` are skipped.** A key is only empty if the row never went
through `TaxStore` — which should be impossible — and grouping every such row together
would merge unrelated entries. Skipping is the safe direction.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxDataTests/ReconciliationTests.swift`.

Include this suite alongside the entry suite below:

```swift
@Suite("Year reconciliation") struct YearReconciliationTests {

    @Test("two TaxYear rows for one year collapse, keeping the newest")
    func duplicateYearsCollapse() async throws {
        let store = try await StoreFixture.store()
        // The collision CloudKit can produce but one device cannot: two live TaxYear
        // rows for 2025, created offline on two devices before the first sync.
        var older = YearFacts()
        older.grossIncome = Money(ringgit: 100_000)
        try await store.saveYearFacts(older, for: 2025)

        await store.useClock { StoreFixture.epoch.addingTimeInterval(60) }
        try await store.insertDuplicateYearForTesting(2025, grossIncome: Money(ringgit: 128_000))

        #expect(try await store.liveYearRowCount(2025) == 2)
        #expect(try await store.reconcileYears() == 1)
        #expect(try await store.liveYearRowCount(2025) == 1)
        #expect(try await store.yearFacts(for: 2025).grossIncome == Money(ringgit: 128_000))
    }

    @Test("the survivor adopts facts it does not have, and never overwrites its own")
    func factsMergeByFillingGaps() async throws {
        let store = try await StoreFixture.store()
        var older = YearFacts()
        older.grossIncome = Money(ringgit: 100_000)
        older.maritalStatus = .married          // the newer row will not have this
        try await store.saveYearFacts(older, for: 2025)

        await store.useClock { StoreFixture.epoch.addingTimeInterval(60) }
        try await store.insertDuplicateYearForTesting(2025, grossIncome: Money(ringgit: 128_000))
        _ = try await store.reconcileYears()

        let facts = try await store.yearFacts(for: 2025)
        // Newer answer wins where both answered...
        #expect(facts.grossIncome == Money(ringgit: 128_000))
        // ...and an answer the user gave on their other phone is adopted, not discarded.
        // nil means "not answered yet" everywhere in this app, so filling a gap cannot
        // lose an answer.
        #expect(facts.maritalStatus == .married)
    }

    @Test("entries on a losing row are re-pointed, not orphaned")
    func entriesFollowTheSurvivor() async throws {
        let store = try await StoreFixture.store()
        _ = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))

        await store.useClock { StoreFixture.epoch.addingTimeInterval(60) }
        try await store.insertDuplicateYearForTesting(2025, grossIncome: nil)
        _ = try await store.reconcileYears()

        // The entry was attached to the row that lost. If it were not re-pointed it would
        // hang off a soft-deleted year and vanish from the user's own records.
        let drafts = try await store.entryDrafts(forYear: 2025)
        #expect(drafts.count == 1)
        #expect(drafts.first?.code == ReliefCode("LIFESTYLE"))
    }

    @Test("running year reconciliation twice changes nothing the second time")
    func yearSweepIsIdempotent() async throws {
        let store = try await StoreFixture.store()
        try await store.saveYearFacts(YearFacts(), for: 2025)
        await store.useClock { StoreFixture.epoch.addingTimeInterval(60) }
        try await store.insertDuplicateYearForTesting(2025, grossIncome: nil)

        #expect(try await store.reconcileYears() == 1)
        #expect(try await store.reconcileYears() == 0)
    }

    @Test("distinct years are left alone")
    func distinctYearsSurvive() async throws {
        let store = try await StoreFixture.store()
        try await store.saveYearFacts(YearFacts(), for: 2024)
        try await store.saveYearFacts(YearFacts(), for: 2025)
        #expect(try await store.reconcileYears() == 0)
        #expect(try await store.liveYears() == [2024, 2025])
    }
}
```

Then the entry-level suite:

```swift
import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Reconciliation") struct ReconciliationTests {

    static let t0 = StoreFixture.epoch
    static let t1 = StoreFixture.epoch.addingTimeInterval(60)

    /// Saves a draft at a controlled instant, so tests can pin which row is "newest".
    static func save(_ store: TaxStore, _ draft: EntryDraft, at instant: Date) async throws -> UUID {
        await store.useClock { instant }
        return try await store.save(draft)
    }

    @Test("a duplicate collapses onto the newest row")
    func duplicateCollapses() async throws {
        let store = try await StoreFixture.store()
        var older = StoreFixture.entry("LIFESTYLE", 1_820)
        var newer = StoreFixture.entry("LIFESTYLE", 1_820)
        older.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        newer.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        _ = try await Self.save(store, older, at: Self.t0)
        _ = try await Self.save(store, newer, at: Self.t1)

        let reports = try await store.reconcile()
        #expect(reports.count == 1)
        #expect(reports.first?.survivorID == newer.id)
        #expect(reports.first?.mergedIDs == [older.id])

        let live = try await store.entryDrafts(forYear: 2025)
        #expect(live.count == 1)
        #expect(live.first?.id == newer.id)
        #expect(try await store.mergedInto(entryID: older.id) == newer.id)
    }

    @Test("the survivor inherits the losers' documents")
    func documentLinksAreUnioned() async throws {
        let store = try await StoreFixture.store()
        var older = StoreFixture.entry("MEDICAL_SERIOUS", 6_500)
        var newer = StoreFixture.entry("MEDICAL_SERIOUS", 6_500)
        older.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        newer.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        _ = try await Self.save(store, older, at: Self.t0)
        _ = try await Self.save(store, newer, at: Self.t1)

        // The older row is the one that carries the medical certificate. Dropping it
        // would turn a complete claim into one failing its requirement check — the merge
        // would destroy evidence, which is the one thing it must never do.
        try await store.attachDocumentForTesting(kind: .medicalCertificate, toEntry: older.id)
        try await store.attachDocumentForTesting(kind: .officialReceipt, toEntry: newer.id)

        _ = try await store.reconcile()

        let survivor = try #require(try await store.entryDrafts(forYear: 2025).first)
        #expect(survivor.id == newer.id)
        #expect(survivor.documentKinds == [.medicalCertificate, .officialReceipt])
    }

    @Test("two devices seeing the same rows in opposite orders pick the same survivor")
    func sweepIsOrderIndependent() async throws {
        var a = StoreFixture.entry("LIFESTYLE", 1_820)
        var b = StoreFixture.entry("LIFESTYLE", 1_820)
        a.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        b.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

        let deviceOne = try await StoreFixture.store()
        _ = try await Self.save(deviceOne, a, at: Self.t0)
        _ = try await Self.save(deviceOne, b, at: Self.t0)

        let deviceTwo = try await StoreFixture.store()
        _ = try await Self.save(deviceTwo, b, at: Self.t0)
        _ = try await Self.save(deviceTwo, a, at: Self.t0)

        let one = try await deviceOne.reconcile()
        let two = try await deviceTwo.reconcile()

        // Identical stamps, so the tie-break is doing the work. Without it the two
        // devices pick different survivors, then resurrect each other's soft-deleted
        // rows on the next sync and the duplicate never goes away.
        #expect(one.first?.survivorID == two.first?.survivorID)
        #expect(one.first?.survivorID == b.id, "highest uuidString wins the tie")
    }

    @Test("a three-way duplicate collapses to one row")
    func threeWayCollapse() async throws {
        let store = try await StoreFixture.store()
        for (index, instant) in [Self.t0, Self.t1, Self.t0].enumerated() {
            var draft = StoreFixture.entry("SSPN", 3_000)
            draft.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!
            _ = try await Self.save(store, draft, at: instant)
        }
        let reports = try await store.reconcile()
        #expect(reports.count == 1)
        #expect(reports.first?.mergedIDs.count == 2)
        #expect(try await store.entryDrafts(forYear: 2025).count == 1)
    }

    @Test("running the sweep twice changes nothing the second time")
    func sweepIsIdempotent() async throws {
        let store = try await StoreFixture.store()
        var older = StoreFixture.entry("LIFESTYLE", 1_820)
        var newer = StoreFixture.entry("LIFESTYLE", 1_820)
        older.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        newer.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        _ = try await Self.save(store, older, at: Self.t0)
        _ = try await Self.save(store, newer, at: Self.t1)

        #expect(try await store.reconcile().count == 1)
        // The sweep runs on every sync-complete event. If it were not idempotent it
        // would churn updatedAt on every sync, which would in turn look like a change
        // to every other device — an infinite sync loop.
        #expect(try await store.reconcile().isEmpty)
        #expect(try await store.entryDrafts(forYear: 2025).count == 1)
    }

    @Test("entries that merely look similar are left alone")
    func distinctEntriesSurvive() async throws {
        let store = try await StoreFixture.store()
        var a = StoreFixture.entry("LIFESTYLE", 1_820, vendor: "Popular Bookstore")
        var b = StoreFixture.entry("LIFESTYLE", 1_820, vendor: "MPH Bookstores")
        var c = StoreFixture.entry("LIFESTYLE", 1_821, vendor: "Popular Bookstore")
        a.id = UUID(); b.id = UUID(); c.id = UUID()
        for draft in [a, b, c] { _ = try await Self.save(store, draft, at: Self.t0) }

        #expect(try await store.reconcile().isEmpty)
        #expect(try await store.entryDrafts(forYear: 2025).count == 3)
    }

    @Test("a merge can be undone")
    func unmergeRestores() async throws {
        let store = try await StoreFixture.store()
        var older = StoreFixture.entry("LIFESTYLE", 1_820)
        var newer = StoreFixture.entry("LIFESTYLE", 1_820)
        older.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        newer.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        _ = try await Self.save(store, older, at: Self.t0)
        _ = try await Self.save(store, newer, at: Self.t1)
        _ = try await store.reconcile()

        try await store.unmerge(entryID: older.id)
        let live = try await store.entryDrafts(forYear: 2025)
        // An automatic, irreversible merge of someone's tax records is not something
        // this app should be able to do. Spec §6.4 requires the merge be reversible.
        #expect(live.count == 2)
        #expect(try await store.mergedInto(entryID: older.id) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter Reconciliation`
Expected: FAIL — "value of type 'TaxStore' has no member 'reconcile'".

- [ ] **Step 3: Write the sweep**

Create `Sources/TaxData/Dedupe/Reconciliation.swift`:

```swift
import Foundation
import SwiftData
import TaxKit

/// One group of duplicates that was collapsed.
public struct MergeReport: Hashable, Sendable {
    public var dedupeKey: String
    public var survivorID: UUID
    /// Sorted, so two devices produce identical reports for identical data.
    public var mergedIDs: [UUID]
}

extension TaxStore {

    /// Collapses duplicate entries. Runs on every sync-complete event.
    ///
    /// Deterministic by construction: the survivor is the row with the newest
    /// `updatedAt`, ties broken on `id.uuidString`. Nothing coordinates the devices, so
    /// the survivor has to be a pure function of the rows — if two devices disagreed,
    /// each would resurrect the other's soft-deleted loser and the duplicate would
    /// survive forever.
    ///
    /// Idempotent: a second run over already-merged data reports nothing and writes
    /// nothing. It has to be, or every sync would churn `updatedAt` and look like a
    /// change to every other device.
    @discardableResult
    public func reconcile() throws -> [MergeReport] {
        // Years first: the entry key includes the year, so an entry re-pointed at the
        // surviving year must be re-keyed before the entry pass groups on it.
        try reconcileYears()

        let live = try modelContext.fetch(
            FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.deletedAt == nil }))

        // An empty key means the row never went through `save`, which should be
        // impossible. Grouping all such rows together would merge unrelated entries, so
        // they are skipped — the safe direction.
        let groups = Dictionary(grouping: live.filter { !$0.dedupeKey.isEmpty },
                                by: \.dedupeKey)

        var reports: [MergeReport] = []
        let stamp = now()

        for key in groups.keys.sorted() {
            guard let group = groups[key], group.count > 1 else { continue }

            let ordered = group.sorted { left, right in
                if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
                return left.id.uuidString > right.id.uuidString
            }
            guard let survivor = ordered.first else { continue }
            let losers = Array(ordered.dropFirst())

            var documents = survivor.documents ?? []
            for loser in losers {
                for document in loser.documents ?? [] where !documents.contains(where: { $0.id == document.id }) {
                    documents.append(document)
                }
                loser.deletedAt = stamp
                loser.updatedAt = stamp
                loser.mergedInto = survivor.id
            }
            // Dropping a loser's documents would turn a complete claim into one failing
            // its requirement check. The merge must never destroy evidence.
            survivor.documents = documents.sorted { $0.id.uuidString < $1.id.uuidString }
            // The union changed this entry's attached document kinds, and `needsDocument`
            // caches exactly that. Without this the survivor keeps reporting a missing
            // document while holding the certificate it just inherited.
            refreshDerivedFields(on: survivor)
            survivor.updatedAt = stamp

            reports.append(MergeReport(dedupeKey: key,
                                       survivorID: survivor.id,
                                       mergedIDs: losers.map(\.id).sorted { $0.uuidString < $1.uuidString }))
        }

        if !reports.isEmpty { try modelContext.save() }
        return reports
    }

    /// Reverses one merge, bringing a soft-deleted loser back as its own entry.
    ///
    /// **Known limitation:** the restored row is a duplicate again, so the next
    /// `reconcile()` re-merges it. Resolving that needs a "the user decided these are
    /// different" marker, which belongs with the merge UI in a later plan.
    ///
    /// `updatedAt` is deliberately NOT stamped. Stamping it would make the restored loser
    /// newer than the survivor, so the next sweep would not merely re-merge — it would
    /// INVERT which row survives, and the user would watch a different entry disappear.
    public func unmerge(entryID: UUID) throws {
        let descriptor = FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == entryID })
        guard let row = try modelContext.fetch(descriptor).first, row.mergedInto != nil else { return }
        row.mergedInto = nil
        row.deletedAt = nil
        try modelContext.save()
    }

    public func mergedInto(entryID: UUID) throws -> UUID? {
        let descriptor = FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == entryID })
        return try modelContext.fetch(descriptor).first?.mergedInto
    }

    /// Collapses duplicate `TaxYear` rows, returning how many were merged away.
    ///
    /// Two devices first launching offline each create their own row for the same year.
    /// Task 4 made the *selection* deterministic so both devices at least agree; this
    /// removes the duplicate.
    ///
    /// Facts merge by filling gaps and never by overwriting: `nil` means "not answered
    /// yet" everywhere in this app, so adopting a loser's value where the survivor has
    /// none cannot lose an answer, while refusing to overwrite means the newer device's
    /// answer always wins. Discarding the loser's facts would silently throw away income
    /// the user entered on their other phone.
    @discardableResult
    public func reconcileYears() throws -> Int {
        let live = try modelContext.fetch(
            FetchDescriptor<TaxYear>(predicate: #Predicate { $0.deletedAt == nil }))

        var merged = 0
        let stamp = now()

        for (_, group) in Dictionary(grouping: live, by: \.year) where group.count > 1 {
            // `TaxStore.isNewer` is the one home for the TaxYear ordering, shared with
            // `fetchOrCreateYear` and `yearFacts`. If a second copy drifted, this sweep
            // would soft-delete the row those two consider authoritative.
            let ordered = group.sorted(by: TaxStore.isNewer)
            guard let survivor = ordered.first else { continue }

            for loser in ordered.dropFirst() {
                Self.fillGaps(on: survivor, from: loser)
                // Re-point rather than orphan: an entry left hanging off a soft-deleted
                // year would vanish from the user's own records.
                // Snapshot first: reassigning `entry.taxYear` mutates the inverse of
                // the very collection being walked, and a skipped element would orphan
                // an entry on a soft-deleted year.
                for entry in Array(loser.entries ?? []) {
                    entry.taxYear = survivor
                    entry.updatedAt = stamp
                }
                loser.deletedAt = stamp
                loser.updatedAt = stamp
                merged += 1
            }
            survivor.updatedAt = stamp
        }

        if merged > 0 { try modelContext.save() }
        return merged
    }

    /// Copies every fact the survivor has not answered from the loser. Never overwrites.
    private static func fillGaps(on survivor: TaxYear, from loser: TaxYear) {
        if survivor.grossIncomeSen == nil { survivor.grossIncomeSen = loser.grossIncomeSen }
        if survivor.epfSen == nil { survivor.epfSen = loser.epfSen }
        if survivor.socsoSen == nil { survivor.socsoSen = loser.socsoSen }
        if survivor.maritalStatusRaw == nil { survivor.maritalStatusRaw = loser.maritalStatusRaw }
        if survivor.spouseHasIncome == nil { survivor.spouseHasIncome = loser.spouseHasIncome }
        if survivor.assessmentTypeRaw == nil { survivor.assessmentTypeRaw = loser.assessmentTypeRaw }
        if survivor.employmentTypeRaw == nil { survivor.employmentTypeRaw = loser.employmentTypeRaw }
        if survivor.genderRaw == nil { survivor.genderRaw = loser.genderRaw }
        if survivor.propertyPriceSen == nil { survivor.propertyPriceSen = loser.propertyPriceSen }
        if survivor.selfIsDisabled == nil { survivor.selfIsDisabled = loser.selfIsDisabled }
        if survivor.spouseIsDisabled == nil { survivor.spouseIsDisabled = loser.spouseIsDisabled }
    }
}

// MARK: - Test-only seams

extension TaxStore {

    /// Attaches a bare document of a given kind. The real pipeline is a later plan; the
    /// sweep only needs the links to exist.
    /// Creates the second live `TaxYear` row for a year that only two devices syncing
    /// can otherwise produce.
    func insertDuplicateYearForTesting(_ year: Int, grossIncome: Money?) throws {
        let row = TaxYear(year: year)
        row.grossIncome = grossIncome
        row.updatedAt = now()
        modelContext.insert(row)
        try modelContext.save()
    }

    func liveYearRowCount(_ year: Int) throws -> Int {
        try modelContext
            .fetch(FetchDescriptor<TaxYear>(predicate: #Predicate { $0.deletedAt == nil }))
            .filter { $0.year == year }
            .count
    }

    func attachDocumentForTesting(kind: DocumentKind, toEntry id: UUID) throws {
        let descriptor = FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == id })
        guard let row = try modelContext.fetch(descriptor).first else { return }
        let document = Document()
        document.kind = kind
        document.updatedAt = now()
        modelContext.insert(document)
        row.documents = (row.documents ?? []) + [document]
        row.updatedAt = now()
        try modelContext.save()
    }
}
```

**Note on `unmerge` and the sweep:** restoring a loser makes its group a duplicate again,
so the next `reconcile()` would immediately re-merge it. That is a real gap, not a
theoretical one — the user's undo would be silently reversed on the next sync. Resolving
it properly needs a "the user has decided these are different" marker, which is a UI
concern this plan does not build (there is no merge screen yet). **Record this in the
ledger as a known limitation**: `unmerge` is currently only safe to call when the sweep
will not run before the user edits one of the rows. The Documents-tab plan that adds the
merge UI must add the marker at the same time.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter Reconciliation`
Expected: PASS — 12 tests in 2 suites.

The order-independence test must be observed failing for the right reason before you
trust it. Temporarily delete the `id.uuidString` tie-break line, re-run, and confirm the
test fails; restore it. A determinism test that has never seen non-determinism is
decoration.

- [ ] **Step 5: Commit**

```bash
git add Sources/TaxData Tests/TaxDataTests
git commit -m "feat: add the deterministic reconciliation sweep with reversible merges"
```

---

### Task 7: Age resolution and the projection into the engine's snapshots

**Files:**
- Create: `Sources/TaxData/Projection/AgeCalculator.swift`
- Create: `Sources/TaxData/Projection/Projection.swift`
- Test: `Tests/TaxDataTests/ProjectionTests.swift`

**Interfaces:**
- Consumes: `TaxStore` reads from Task 4; `TaxYearSnapshot`, `DependentSnapshot`,
  `EntrySnapshot`, `Money`, `ReliefCode` from `TaxKit`.
- Produces:
  - `enum AgeCalculator { static func age(bornOn: Date, atEndOf year: Int) -> Int }`
  - `struct ProjectedYear: Sendable { var snapshot: TaxYearSnapshot; var entries: [EntrySnapshot] }`
  - `TaxStore.project(year: Int) throws -> ProjectedYear`

**This is the seam.** Everything above it is SwiftData; everything below it is the pure
engine Plan 1 golden-file tested. `evaluate` takes `TaxYearSnapshot` and `[EntrySnapshot]`
and nothing else, so this function is the entire contract between the two halves of the
app. Task 8 proves it by driving Plan 1's golden persona through the store and asserting
the engine still produces `golden-ya2025.json`.

**Ages are resolved at 31 December of the Year of Assessment**, on a `.gregorian`
calendar in `Asia/Kuala_Lumpur`. Plan 1 put this responsibility on the caller
deliberately — `DependentSnapshot.ageAtYearEnd` is an `Int?` and its doc comment says
"ages are resolved at year end by the caller, so the engine never touches a calendar".
This is that caller. Using `Date()` here would make the engine's output depend on when it
ran, and every golden file in the suite would rot on 1 January.

**`lastClaimedYear` is derived, and absent history means `.unknown`, not
`.neverClaimed`.** Plan 1's final review settled this: the app cannot know what a user
claimed before they adopted it, and assuming "never" would over-grant a once-every-N-years
relief. So the map only carries codes with an actual prior-year entry in this store; a
code with no history is simply absent from the map, which the engine reads as unknown.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxDataTests/ProjectionTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Age at year end") struct AgeCalculatorTests {

    // 2018-03-14, 2006-06-02, 2009-09-21 — the golden persona's three children.
    static let aisyah = Date(timeIntervalSince1970: 1_521_000_000)
    static let danish = Date(timeIntervalSince1970: 1_149_206_400)
    static let farah  = Date(timeIntervalSince1970: 1_253_491_200)

    @Test("ages match the golden persona at the end of YA2025")
    func personaAges() {
        #expect(AgeCalculator.age(bornOn: Self.aisyah, atEndOf: 2025) == 7)
        #expect(AgeCalculator.age(bornOn: Self.danish, atEndOf: 2025) == 19)
        #expect(AgeCalculator.age(bornOn: Self.farah, atEndOf: 2025) == 16)
    }

    @Test("age is taken at 31 December, not on the day the code runs")
    func ageIsAtYearEnd() {
        // Born 21 September 2009: 15 at the end of 2024, 16 at the end of 2025. If this
        // read the clock instead, every golden file in the suite would rot on 1 January.
        #expect(AgeCalculator.age(bornOn: Self.farah, atEndOf: 2024) == 15)
        #expect(AgeCalculator.age(bornOn: Self.farah, atEndOf: 2025) == 16)
    }

    @Test("a birthday on 31 December counts that year")
    func birthdayOnTheBoundary() {
        // 2010-12-31 08:00 KL.
        let newYearsEve = Date(timeIntervalSince1970: 1_293_753_600)
        #expect(AgeCalculator.age(bornOn: newYearsEve, atEndOf: 2025) == 15)
    }

    @Test("age is negative before birth")
    func ageIsNegativeBeforeBirth() {
        let born2027 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15
        // AgeCalculator is the honest primitive and reports the real signed difference.
        // Turning that into "unknown" is the projection's job, not this one's — see
        // `unbornDependentHasNoAge` in the projection suite.
        #expect(AgeCalculator.age(bornOn: born2027, atEndOf: 2025) < 0)
    }
}

@Suite("Projection") struct ProjectionTests {

    @Test("year facts project into the snapshot the engine consumes")
    func yearFactsProject() async throws {
        let store = try await StoreFixture.store()
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        facts.maritalStatus = .married
        facts.spouseHasIncome = false
        facts.assessmentType = .separate
        facts.employmentType = .privateSector
        facts.gender = .female
        facts.propertyPrice = Money(ringgit: 480_000)
        try await store.saveYearFacts(facts, for: 2025)

        let projected = try await store.project(year: 2025)
        #expect(projected.snapshot.year == 2025)
        #expect(projected.snapshot.grossIncome == Money(ringgit: 128_000))
        #expect(projected.snapshot.maritalStatus == .married)
        #expect(projected.snapshot.propertyPriceSen == 48_000_000)
        #expect(projected.snapshot.selfIsDisabled == nil)
    }

    @Test("dependents project with resolved ages and their year's status")
    func dependentsProject() async throws {
        let store = try await StoreFixture.store()
        var farah = DependentDraft(name: "Farah")
        farah.dateOfBirth = AgeCalculatorTests.farah
        farah.yearStatuses = [
            DependentYearStatus(year: 2024, educationLevel: .none, claimPercentage: 100, isFullTime: true),
            DependentYearStatus(year: 2025, educationLevel: .preTertiary, claimPercentage: 50, isFullTime: true)
        ]
        _ = try await store.save(farah)

        let projected = try await store.project(year: 2025)
        let dependent = try #require(projected.snapshot.dependents.first)
        #expect(dependent.ageAtYearEnd == 16)
        #expect(dependent.educationLevel == .preTertiary)
        #expect(dependent.claimPercentage == 50)
        #expect(dependent.isDisabled == nil)
    }

    @Test("a dependent with no status for the year projects education as nil")
    func missingStatusProjectsNil() async throws {
        let store = try await StoreFixture.store()
        var danish = DependentDraft(name: "Danish")
        danish.dateOfBirth = AgeCalculatorTests.danish
        _ = try await store.save(danish)

        let projected = try await store.project(year: 2025)
        let dependent = try #require(projected.snapshot.dependents.first)
        #expect(dependent.ageAtYearEnd == 19)
        #expect(dependent.educationLevel == nil, "unanswered, so the engine prompts")
        #expect(dependent.claimPercentage == 100, "the default share, not a guess about education")
    }

    @Test("a dependent with no date of birth projects a nil age")
    func missingBirthDateProjectsNilAge() async throws {
        let store = try await StoreFixture.store()
        _ = try await store.save(DependentDraft(name: "Unknown"))
        let projected = try await store.project(year: 2025)
        #expect(projected.snapshot.dependents.first?.ageAtYearEnd == nil)
    }

    @Test("entries project with their code, amount, claimant and document kinds")
    func entriesProject() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(StoreFixture.entry("MEDICAL_SERIOUS", 6_500))
        try await store.attachDocumentForTesting(kind: .officialReceipt, toEntry: id)
        try await store.attachDocumentForTesting(kind: .medicalCertificate, toEntry: id)

        let projected = try await store.project(year: 2025)
        let entry = try #require(projected.entries.first)
        #expect(entry.id == id)
        #expect(entry.code == ReliefCode("MEDICAL_SERIOUS"))
        #expect(entry.amount == Money(ringgit: 6_500))
        #expect(entry.claimant == .individual)
        #expect(entry.documentKinds == [.officialReceipt, .medicalCertificate])
    }

    @Test("soft-deleted and merged entries do not reach the engine")
    func deletedEntriesAreExcluded() async throws {
        let store = try await StoreFixture.store()
        let kept = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))
        var other = StoreFixture.entry("SSPN", 3_000)
        other.id = UUID()
        let removed = try await store.save(other)
        try await store.softDeleteEntry(id: removed)

        let projected = try await store.project(year: 2025)
        // A deleted entry that still reduced chargeable income would understate tax on a
        // figure the user believes they removed.
        #expect(projected.entries.map(\.id) == [kept])
    }

    @Test("prior-year claims become claim history, and no history means absent")
    func claimHistoryIsDerived() async throws {
        let store = try await StoreFixture.store()
        _ = try await store.save(StoreFixture.entry("LIFESTYLE_PC", 2_500, year: 2023))
        var current = StoreFixture.entry("LIFESTYLE", 1_820, year: 2025)
        current.id = UUID()
        _ = try await store.save(current)

        let projected = try await store.project(year: 2025)
        #expect(projected.snapshot.lastClaimedYear[ReliefCode("LIFESTYLE_PC")] == 2023)
        // Absent, not zero and not "never": the app cannot know what the user claimed
        // before they adopted it, and assuming "never" would over-grant a
        // once-every-N-years relief. Absent reads as .unknown in the engine.
        #expect(projected.snapshot.lastClaimedYear[ReliefCode("SSPN")] == nil)
    }

    @Test("the current year is not its own claim history")
    func currentYearIsNotHistory() async throws {
        let store = try await StoreFixture.store()
        _ = try await store.save(StoreFixture.entry("LIFESTYLE_PC", 2_500, year: 2025))
        let projected = try await store.project(year: 2025)
        // Otherwise every relief claimed this year would immediately look like it was
        // "last claimed 0 years ago" and block itself.
        #expect(projected.snapshot.lastClaimedYear[ReliefCode("LIFESTYLE_PC")] == nil)
    }

    @Test("a dependent born after the year end has no age, not a negative one")
    func unbornDependentHasNoAge() async throws {
        let store = try await StoreFixture.store()
        var unborn = DependentDraft(name: "Not yet")
        unborn.dateOfBirth = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15
        _ = try await store.save(unborn)

        let projected = try await store.project(year: 2025)
        // The engine's dependentAge(max:) tests `age > max`, so a negative age passes an
        // "under 18" check and the household would be granted RM 2,000 of child relief
        // for a dependent who does not exist yet.
        #expect(projected.snapshot.dependents.first?.ageAtYearEnd == nil)
    }

    @Test("dependents project in a stable order")
    func dependentsAreOrdered() async throws {
        let store = try await StoreFixture.store()
        for name in ["Farah", "Aisyah", "Danish"] {
            _ = try await store.save(DependentDraft(id: UUID(), name: name))
        }
        let first = try await store.project(year: 2025).snapshot.dependents.map(\.id)
        let second = try await store.project(year: 2025).snapshot.dependents.map(\.id)
        #expect(first == second)
        #expect(first == first.sorted { $0.uuidString < $1.uuidString })
    }

    @Test("projection is ordered deterministically")
    func projectionIsOrdered() async throws {
        let store = try await StoreFixture.store()
        for code in ["SSPN", "LIFESTYLE", "MEDICAL_CHECKUP"] {
            var draft = StoreFixture.entry(code, 100)
            draft.id = UUID()
            _ = try await store.save(draft)
        }
        let first = try await store.project(year: 2025).entries.map(\.id)
        let second = try await store.project(year: 2025).entries.map(\.id)
        #expect(first == second)
        #expect(first == first.sorted { $0.uuidString < $1.uuidString })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "Projection|AgeCalculator"`
Expected: FAIL — "cannot find 'AgeCalculator' in scope".

- [ ] **Step 3: Write the age calculator**

Create `Sources/TaxData/Projection/AgeCalculator.swift`:

```swift
import Foundation

/// Ages, resolved at the end of a Year of Assessment.
///
/// The engine deliberately never touches a calendar — `DependentSnapshot.ageAtYearEnd`
/// is an already-resolved `Int?` — because a rules engine that reads the clock produces
/// different answers on different days and its golden files rot every 1 January. This is
/// the one place a calendar is consulted, and it takes the year as a parameter rather
/// than reading `Date()`.
public enum AgeCalculator {

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// Completed years of age on 31 December of `year`, in Kuala Lumpur.
    public static func age(bornOn birthDate: Date, atEndOf year: Int) -> Int {
        var components = DateComponents()
        components.year = year
        components.month = 12
        components.day = 31
        components.hour = 23
        components.minute = 59
        guard let yearEnd = calendar.date(from: components) else { return 0 }
        return calendar.dateComponents([.year], from: birthDate, to: yearEnd).year ?? 0
    }
}
```

- [ ] **Step 4: Write the projection**

Create `Sources/TaxData/Projection/Projection.swift`:

```swift
import Foundation
import SwiftData
import TaxKit

/// Everything `evaluate(ruleSet:year:entries:)` needs, and nothing else.
public struct ProjectedYear: Hashable, Sendable {
    public var snapshot: TaxYearSnapshot
    public var entries: [EntrySnapshot]
}

extension TaxStore {

    /// The seam between the store and the engine.
    ///
    /// Everything above this line is SwiftData; everything below it is the pure function
    /// Plan 1 golden-file tested. Ordering is deterministic so two devices, and two runs,
    /// produce byte-identical input to the engine.
    public func project(year: Int) throws -> ProjectedYear {
        let facts = try yearFacts(for: year)
        let entries = try entryDrafts(forYear: year)
        let dependents = try dependentDrafts()

        var snapshot = TaxYearSnapshot(year: year)
        snapshot.grossIncome = facts.grossIncome
        snapshot.maritalStatus = facts.maritalStatus
        snapshot.spouseHasIncome = facts.spouseHasIncome
        snapshot.assessmentType = facts.assessmentType
        snapshot.employmentType = facts.employmentType
        snapshot.gender = facts.gender
        snapshot.propertyPriceSen = facts.propertyPrice?.sen
        snapshot.selfIsDisabled = facts.selfIsDisabled
        snapshot.spouseIsDisabled = facts.spouseIsDisabled
        snapshot.dependents = dependents.map { Self.dependentSnapshot($0, forYear: year) }
        snapshot.lastClaimedYear = try claimHistory(before: year)

        return ProjectedYear(
            snapshot: snapshot,
            entries: entries.map { draft in
                EntrySnapshot(id: draft.id,
                              code: draft.code,
                              amount: draft.amount,
                              claimant: draft.claimant,
                              dependentID: draft.dependentID,
                              documentKinds: draft.documentKinds)
            })
    }

    static func dependentSnapshot(_ draft: DependentDraft, forYear year: Int) -> DependentSnapshot {
        let status = draft.yearStatuses.first { $0.year == year }
        return DependentSnapshot(
            id: draft.id,
            name: draft.name,
            // A negative age means the recorded birth date is after the year end — bad
            // data, or a placeholder. It must not reach the engine: `dependentAge(max:)`
            // tests `age > max`, so -1 passes a "under 18" check and a not-yet-born
            // dependent would be granted child relief. nil reaches the engine as an
            // unanswered question, so the relief prompts instead of being granted.
            ageAtYearEnd: draft.dateOfBirth
                .map { AgeCalculator.age(bornOn: $0, atEndOf: year) }
                .flatMap { $0 >= 0 ? $0 : nil },
            // nil, not `.none`: an unrecorded education level is an unanswered question,
            // and the engine renders it as a prompt rather than as ineligibility.
            educationLevel: status?.educationLevel,
            isDisabled: draft.isDisabled,
            claimPercentage: status?.claimPercentage ?? 100)
    }

    /// The most recent prior year in which each code was claimed.
    ///
    /// Only codes with an actual entry in this store appear. A code with no history is
    /// absent, which the engine reads as `.unknown` — the app cannot know what a user
    /// claimed before adopting it, and assuming "never" would over-grant a
    /// once-every-N-years relief.
    private func claimHistory(before year: Int) throws -> [ReliefCode: Int] {
        let rows = try modelContext.fetch(
            FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.deletedAt == nil }))

        var history: [ReliefCode: Int] = [:]
        for row in rows {
            guard let rowYear = row.taxYear?.year, rowYear < year else { continue }
            let code = row.reliefCode
            history[code] = max(history[code] ?? Int.min, rowYear)
        }
        return history
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "Projection|AgeCalculator"`
Expected: PASS — 13 tests in 2 suites.

- [ ] **Step 6: Commit**

```bash
git add Sources/TaxData Tests/TaxDataTests
git commit -m "feat: project the persisted graph into the engine's snapshot types"
```

---

### Task 8: The persisted persona reproduces Plan 1's golden file

**Files:**
- Test: `Tests/TaxDataTests/PersistedGoldenTests.swift`

**Interfaces:**
- Consumes: everything in Tasks 1–7; `BundledRuleSetLoader`, `evaluate`,
  `EvaluationResult` from `TaxKit`; the existing
  `Tests/TaxKitTests/Fixtures/golden-ya2025.json`.
- Produces: no new source. This task is the proof that Phase A is correct.

**Why this is a task and not an assertion inside Task 7.** Tasks 1–7 each proved a piece
in isolation, and every one of them could pass while the assembled stack is wrong — a
dropped claim percentage, a dependent id that does not survive the round trip, an entry
ordering that changes what the evaluator sees. Plan 1 shipped a golden file recording
exactly what the engine produces for a fully specified household. If the persistence
layer can seed that household through `TaxStore`, project it, and get the *same
EvaluationResult back*, then the seam holds end to end. If it cannot, the difference
names the bug.

**One golden file, referenced across suites, deliberately.** The test reaches into
`Tests/TaxKitTests/Fixtures/` by relative path rather than copying the JSON into
`TaxDataTests`. A copy would let the two drift, and a drifted golden file asserts nothing
while looking like it does.

**The persona's UUIDs are reused verbatim.** `EvaluationResult.unresolved` carries entry
ids, so seeding with fresh UUIDs would produce a result that differs from the golden file
in a way that has nothing to do with correctness. `EntryDraft` and `DependentDraft` both
take an explicit `id` for exactly this.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxDataTests/PersistedGoldenTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
@testable import TaxData

/// The same household Plan 1's `GoldenFileTests` describes, seeded through `TaxStore`
/// rather than constructed as snapshots in memory.
@Suite("Persisted golden persona") struct PersistedGoldenTests {

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
    }

    /// Birth dates chosen to resolve to the persona's ages at the end of YA2025:
    /// 7, 19 and 16 respectively.
    static let aisyahBorn = Date(timeIntervalSince1970: 1_521_000_000)   // 2018-03-14
    static let danishBorn = Date(timeIntervalSince1970: 1_149_206_400)   // 2006-06-02
    static let farahBorn  = Date(timeIntervalSince1970: 1_253_491_200)   // 2009-09-21

    static func seed(_ store: TaxStore) async throws {
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        facts.maritalStatus = .married
        facts.spouseHasIncome = false
        facts.assessmentType = .separate
        facts.employmentType = .privateSector
        facts.gender = .female
        facts.propertyPrice = Money(ringgit: 480_000)
        try await store.saveYearFacts(facts, for: 2025)

        var aisyah = DependentDraft(id: id(101), name: "Aisyah")
        aisyah.dateOfBirth = aisyahBorn
        aisyah.yearStatuses = [DependentYearStatus(year: 2025, educationLevel: .none,
                                                   claimPercentage: 100, isFullTime: false)]
        var danish = DependentDraft(id: id(102), name: "Danish")
        danish.dateOfBirth = danishBorn
        danish.yearStatuses = [DependentYearStatus(year: 2025, educationLevel: .tertiaryLocal,
                                                   claimPercentage: 100, isFullTime: true)]
        var farah = DependentDraft(id: id(103), name: "Farah")
        farah.dateOfBirth = farahBorn
        farah.yearStatuses = [DependentYearStatus(year: 2025, educationLevel: .preTertiary,
                                                  claimPercentage: 50, isFullTime: true)]
        for dependent in [aisyah, danish, farah] { _ = try await store.save(dependent) }

        let entries: [(Int, String, Decimal, UUID?, Set<DocumentKind>)] = [
            (1,  "LIFESTYLE",             1_820, nil,      [.officialReceipt]),
            (2,  "LIFESTYLE_SPORTS",      1_400, nil,      [.officialReceipt]),
            (3,  "MEDICAL_SERIOUS",       6_500, nil,      [.officialReceipt, .medicalCertificate]),
            (4,  "MEDICAL_CHECKUP",         900, nil,      [.officialReceipt]),
            (5,  "EPF_CONTRIBUTION",      4_600, nil,      [.epfStatement]),
            (6,  "LIFE_INSURANCE",        2_100, nil,      []),
            (7,  "SSPN",                  3_000, nil,      [.bankStatement]),
            (8,  "CHILDCARE",             2_400, id(101),  [.officialReceipt]),
            (9,  "HOUSING_LOAN_INTEREST", 9_100, nil,      [.bankStatement]),
            (10, "SOCSO_EIS",               350, nil,      [])
        ]

        for (number, code, ringgit, dependentID, documents) in entries {
            let draft = EntryDraft(id: id(number),
                                   year: 2025,
                                   code: ReliefCode(code),
                                   amount: Money(ringgit: ringgit),
                                   dependentID: dependentID)
            let saved = try await store.save(draft)
            for kind in documents.sorted(by: { $0.rawValue < $1.rawValue }) {
                try await store.attachDocumentForTesting(kind: kind, toEntry: saved)
            }
        }
    }

    /// The single golden file, in `TaxKitTests`. Referenced rather than copied so the
    /// two suites cannot drift apart.
    static var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/TaxDataTests
            .deletingLastPathComponent()      // Tests
            .appending(path: "TaxKitTests/Fixtures/golden-ya2025.json")
    }

    static func evaluatePersisted(_ store: TaxStore) async throws -> EvaluationResult {
        let projected = try await store.project(year: 2025)
        let ruleSet = try BundledRuleSetLoader().ruleSet(for: 2025)
        return evaluate(ruleSet: ruleSet, year: projected.snapshot, entries: projected.entries)
    }

    @Test("seeding through TaxStore reproduces the golden YA2025 result exactly")
    func persistedPersonaMatchesGolden() async throws {
        let store = try await StoreFixture.store()
        try await Self.seed(store)

        let produced = try await Self.evaluatePersisted(store)
        let expected = try JSONDecoder().decode(EvaluationResult.self,
                                                from: Data(contentsOf: Self.goldenURL))

        // Compare field by field before the whole-value assertion: `#expect(a == b)` on a
        // 30-node tree reports "not equal" and nothing else, which is useless to whoever
        // has to fix it.
        #expect(produced.chargeableIncome == expected.chargeableIncome)
        #expect(produced.estimatedTax == expected.estimatedTax)
        #expect(produced.totalAllowed == expected.totalAllowed)
        #expect(produced.totalOpportunity == expected.totalOpportunity)
        #expect(produced.assessments.map(\.code) == expected.assessments.map(\.code))
        #expect(produced.unresolved == expected.unresolved)

        for expectedAssessment in expected.allAssessments {
            let actual = produced.assessment(for: expectedAssessment.code)
            #expect(actual?.allowed == expectedAssessment.allowed,
                    "\(expectedAssessment.code) allowed")
            #expect(actual?.eligibility == expectedAssessment.eligibility,
                    "\(expectedAssessment.code) eligibility")
            #expect(actual?.taxSaved == expectedAssessment.taxSaved,
                    "\(expectedAssessment.code) taxSaved")
        }

        #expect(produced == expected)
    }

    @Test("the reconciliation sweep does not change the result")
    func sweepPreservesTheResult() async throws {
        let store = try await StoreFixture.store()
        try await Self.seed(store)
        let before = try await Self.evaluatePersisted(store)

        #expect(try await store.reconcile().isEmpty, "the persona contains no duplicates")
        let after = try await Self.evaluatePersisted(store)
        #expect(after == before)
    }

    @Test("a duplicated receipt overstates relief, and the sweep restores the truth")
    func sweepRemovesAnOverstatement() async throws {
        let store = try await StoreFixture.store()
        try await Self.seed(store)
        let golden = try await Self.evaluatePersisted(store)

        // The same RM 1,820 of books logged twice — the exact failure CloudKit's lack of
        // unique constraints makes possible, and the reason the sweep exists.
        var duplicate = EntryDraft(id: UUID(),
                                   year: 2025,
                                   code: ReliefCode("LIFESTYLE"),
                                   amount: Money(ringgit: 1_820))
        duplicate.vendor = ""
        _ = try await store.save(duplicate)

        let inflated = try await Self.evaluatePersisted(store)
        #expect(inflated.assessment(for: ReliefCode("LIFESTYLE"))?.claimed
                != golden.assessment(for: ReliefCode("LIFESTYLE"))?.claimed,
                "the duplicate must actually be visible to the engine, or this proves nothing")

        let reports = try await store.reconcile()
        #expect(reports.count == 1)
        let repaired = try await Self.evaluatePersisted(store)
        #expect(repaired.assessment(for: ReliefCode("LIFESTYLE"))?.claimed
                == golden.assessment(for: ReliefCode("LIFESTYLE"))?.claimed)
    }

    @Test("projecting an empty store still evaluates, granting only automatic reliefs")
    func emptyStoreEvaluates() async throws {
        let store = try await StoreFixture.store()
        let result = try await Self.evaluatePersisted(store)
        // First launch, before onboarding. The screen must show a number, not an error.
        #expect(result.unresolved.isEmpty)
        #expect(result.totalAllowed > Money.zero, "the individual relief is automatic")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PersistedGolden`
Expected: FAIL. The first run is diagnostic — read which field differs.

**Expect the persona to need adjusting, and adjust the seed, not the golden file.** The
golden file is Plan 1's verified output and is not evidence to be edited. The likely
divergences and their correct fixes:

- **A dependent's `claimPercentage` or `educationLevel` differs.** The `DependentYearStatus`
  for 2025 in `seed` is wrong. Plan 1's persona has Aisyah at `EducationLevel.none` with
  100%, Danish `.tertiaryLocal` at 100%, Farah `.preTertiary` at 50%.
- **An age is off by one.** Check the birth date against `AgeCalculator`, not against
  intuition — the constants above are chosen to give 7, 19 and 16 at the end of 2025.
- **`unresolved` entry ids differ.** The seed is not using the persona's UUIDs.
- **`documentKinds` differ for an entry.** `attachDocumentForTesting` creates one
  `Document` per kind; confirm all of them attached.

If instead the difference is a *ringgit figure* that no seed change can explain, stop and
report it. That would mean the projection is losing information the engine needs, which
is a Task 7 bug, not a fixture problem.

- [ ] **Step 3: Make the four tests pass**

Adjust `seed` until `persistedPersonaMatchesGolden` passes.

Run: `swift test --filter PersistedGolden`
Expected: PASS — 4 tests.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS. Phase A is complete: roughly 60 tests across `TaxKitTests` and
`TaxDataTests`, with no regression in Plan 1's 136.

- [ ] **Step 5: Verify TaxKit is still pure and commit**

Run: `grep -rn "import SwiftData\|import SwiftUI" Sources/TaxKit --include=*.swift`
Expected: no output.

```bash
git add Tests/TaxDataTests
git commit -m "test: prove the persisted persona reproduces Plan 1's golden YA2025 result"
```

---

## Phase B — the iOS shell

### Task 9: The generated Xcode project and the simulator build gate

**Files:**
- Create: `project.yml`
- Create: `Config/Signing.example.xcconfig`
- Create: `App/TaxTracker/Info.plist`
- Create: `App/TaxTracker/TaxTracker.entitlements`
- Create: `App/TaxTracker/TaxTrackerApp.swift`
- Create: `App/TaxTracker/RootView.swift`
- Create: `Scripts/build-app.sh`
- Modify: `.gitignore`
- Modify: `Package.swift` (add the `TaxPresentation` target and its tests)

**Interfaces:**
- Consumes: `TaxContainer`, `TaxStore` from `TaxData`.
- Produces:
  - A generated `TaxTracker.xcodeproj` that builds for the iOS 26.1 simulator.
  - `Scripts/build-app.sh` — the one command the Definition of Done runs.
  - `enum StorageMode` resolved from `Info.plist`, choosing `.localOnly` or `.cloudKit`.
  - The empty `TaxPresentation` target, so Task 10 has somewhere to land.

**Why the project file is generated.** A `.pbxproj` is a machine-written file that
merge-conflicts on almost every concurrent change and cannot be reviewed. `project.yml`
is 60 readable lines, and target membership, entitlements and build settings become
ordinary diffs. The `.xcodeproj` is gitignored; `xcodegen generate` reproduces it.

**Why CloudKit is off by default, and how it turns on.** The iCloud entitlement requires
a paid Apple Developer team. Without one the app will not sign, and a plan that cannot
build on the machine executing it is worthless. So:

- `Config/Signing.xcconfig` (gitignored) carries `DEVELOPMENT_TEAM` and
  `TAXTRACKER_ENTITLEMENTS`. `Config/Signing.example.xcconfig` is the committed template
  with both empty.
- With both empty, the app signs for the simulator with no entitlement and
  `Info.plist`'s `RelioStorageMode` is `local`, so `TaxContainer.make(.localOnly(nil))`.
  Everything in this plan works in that mode — spec §6 requires the app be fully usable
  signed out of iCloud anyway.
- Filling in a team and pointing `TAXTRACKER_ENTITLEMENTS` at the entitlements file
  switches `RelioStorageMode` to `cloudKit`.

The mode is a plist value read at launch rather than a `#if`, so both paths compile in
every build and neither can rot unnoticed.

- [ ] **Step 1: Add the `TaxPresentation` target**

Modify `Package.swift` — add to `products`:

```swift
        .library(name: "TaxPresentation", targets: ["TaxPresentation"])
```

and to `targets`:

```swift
        .target(
            name: "TaxPresentation",
            dependencies: ["TaxKit", "TaxData"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
```

and after `TaxDataTests`:

```swift
        .testTarget(
            name: "TaxPresentationTests",
            dependencies: ["TaxPresentation"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
```

Create a placeholder so the target compiles — `Sources/TaxPresentation/YearContext.swift`
is written properly in Task 10; for now:

```swift
import Foundation

/// Placeholder so the target has a source file. Task 10 replaces this.
enum TaxPresentationPlaceholder {}
```

Run: `swift build`
Expected: succeeds.

- [ ] **Step 2: Write the signing template and gitignore the real one**

Create `Config/Signing.example.xcconfig`:

```
// Copy to Config/Signing.xcconfig and fill in to enable CloudKit.
//
// Leave both empty to build and run without an Apple Developer team. The app is fully
// functional in that mode — data is local only, which spec §6 requires anyway for a user
// signed out of iCloud.
//
// With a paid team:
//   DEVELOPMENT_TEAM = ABCDE12345
//   TAXTRACKER_ENTITLEMENTS = App/TaxTracker/TaxTracker.entitlements
//   TAXTRACKER_STORAGE_MODE = cloudKit

DEVELOPMENT_TEAM =
TAXTRACKER_ENTITLEMENTS =
TAXTRACKER_STORAGE_MODE = local
CODE_SIGN_STYLE = Automatic
```

Append to `.gitignore`:

```
# Generated by `xcodegen generate` from project.yml
TaxTracker.xcodeproj/
# Local signing identity — never committed
Config/Signing.xcconfig
```

- [ ] **Step 3: Write `project.yml`**

Create `project.yml`:

```yaml
name: TaxTracker

options:
  bundleIdPrefix: my.relio
  deploymentTarget:
    iOS: "26.0"
  createIntermediateGroups: true
  generateEmptyDirectories: true

configs:
  Debug: debug
  Release: release

# The local Swift package holds ~70% of the code. The app target is views only.
packages:
  TaxKit:
    path: .

fileGroups:
  - project.yml
  - Config/Signing.example.xcconfig

settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    ENABLE_USER_SCRIPT_SANDBOXING: YES
    CLANG_ENABLE_MODULES: YES

targets:
  TaxTracker:
    type: application
    platform: iOS
    sources:
      - path: App/TaxTracker
    dependencies:
      - package: TaxKit
        product: TaxKit
      - package: TaxKit
        product: TaxData
      - package: TaxKit
        product: TaxPresentation
    configFiles:
      Debug: Config/Signing.xcconfig
      Release: Config/Signing.xcconfig
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: my.relio.TaxTracker
        PRODUCT_NAME: Relio
        INFOPLIST_FILE: App/TaxTracker/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        # Empty in the committed template, so the app signs with no entitlement and
        # runs local-only. Filling it in switches CloudKit on.
        CODE_SIGN_ENTITLEMENTS: $(TAXTRACKER_ENTITLEMENTS)
        TARGETED_DEVICE_FAMILY: "1,2"
        SUPPORTS_MACCATALYST: NO

schemes:
  TaxTracker:
    build:
      targets:
        TaxTracker: all
    run:
      config: Debug
```

**`Config/Signing.xcconfig` does not exist yet and `configFiles` requires it.** Create it
by copying the template — it is gitignored, so this is a local-setup step, not a commit:

```bash
cp Config/Signing.example.xcconfig Config/Signing.xcconfig
```

- [ ] **Step 4: Write the Info.plist and entitlements**

Create `App/TaxTracker/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Relio</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <!-- `local` or `cloudKit`, from TAXTRACKER_STORAGE_MODE in Config/Signing.xcconfig.
         A plist value rather than a #if, so both paths compile in every build. -->
    <key>RelioStorageMode</key>
    <string>$(TAXTRACKER_STORAGE_MODE)</string>
</dict>
</plist>
```

Create `App/TaxTracker/TaxTracker.entitlements` (referenced only when a team is set):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.my.relio.TaxTracker</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
    <key>com.apple.developer.ubiquity-container-identifiers</key>
    <array>
        <string>iCloud.my.relio.TaxTracker</string>
    </array>
</dict>
</plist>
```

The ubiquity container is declared now because spec §6 puts full-resolution documents in
iCloud Drive. Nothing in this plan writes to it.

- [ ] **Step 5: Write the app entry point**

Create `App/TaxTracker/TaxTrackerApp.swift`:

```swift
import SwiftUI
import SwiftData
import TaxData

/// How this build stores data, read from `Info.plist` rather than compiled in, so both
/// paths build in every configuration and neither rots unnoticed.
enum StorageMode: String {
    case local
    case cloudKit

    static var current: StorageMode {
        let raw = Bundle.main.object(forInfoDictionaryKey: "RelioStorageMode") as? String
        return StorageMode(rawValue: raw ?? "") ?? .local
    }

    var storage: TaxContainer.Storage {
        switch self {
        case .local: return .localOnly(nil)
        case .cloudKit: return .cloudKit(identifier: nil)
        }
    }
}

@main
struct TaxTrackerApp: App {

    private let container: ModelContainer
    private let store: TaxStore

    init() {
        do {
            container = try TaxContainer.make(StorageMode.current.storage)
        } catch {
            // A container that will not open is not recoverable in-process, and a silent
            // in-memory fallback would let a user enter a year of receipts that are
            // thrown away on quit. Fail loudly instead.
            fatalError("Could not open the data store: \(error)")
        }
        store = TaxStore(modelContainer: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}
```

Create `App/TaxTracker/RootView.swift` — a placeholder Task 12 replaces:

```swift
import SwiftUI
import TaxData

struct RootView: View {
    let store: TaxStore

    var body: some View {
        VStack(spacing: 12) {
            Text("Relio")
                .font(.largeTitle.bold())
            Text("Storage: \(StorageMode.current.rawValue)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
```

- [ ] **Step 6: Write the build script**

Create `Scripts/build-app.sh`:

```bash
#!/usr/bin/env bash
# Generates the Xcode project and builds the app for the iOS simulator.
# This is the gate every UI task runs: `swift test` cannot see SwiftUI, so the only
# automated proof the views compile and link is a real build.
set -euo pipefail

cd "$(dirname "$0")/.."

DEVICE_NAME="Relio Test Phone"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"

if [ ! -f Config/Signing.xcconfig ]; then
  echo "Config/Signing.xcconfig missing — copying the template."
  cp Config/Signing.example.xcconfig Config/Signing.xcconfig
fi

xcodegen generate

# The runtime is installed but this machine may have no devices created.
RUNTIME=$(xcrun simctl list runtimes --json \
  | python3 -c 'import json,sys; rs=[r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and "iOS" in r["name"]]; print(sorted(rs, key=lambda r: r["version"])[-1]["identifier"])')

if ! xcrun simctl list devices | grep -q "$DEVICE_NAME"; then
  echo "Creating simulator '$DEVICE_NAME' on $RUNTIME"
  xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME"
fi

xcodebuild \
  -project TaxTracker.xcodeproj \
  -scheme TaxTracker \
  -destination "platform=iOS Simulator,name=$DEVICE_NAME" \
  -quiet \
  build

echo "Build succeeded."
```

Make it executable:

```bash
chmod +x Scripts/build-app.sh
```

- [ ] **Step 7: Run the gate**

Run: `./Scripts/build-app.sh`
Expected: "Build succeeded."

**If `xcodegen` is not installed**, `brew install xcodegen`. This machine has 2.46.0.

**If signing fails** with "no account for team" or "requires a development team", the
`Config/Signing.xcconfig` copy did not happen or has a non-empty `DEVELOPMENT_TEAM` with
no matching account. An empty team plus an empty `CODE_SIGN_ENTITLEMENTS` signs for the
simulator without an account.

**If the build fails on `SWIFT_STRICT_CONCURRENCY`,** do not lower it. The package is
Swift 6 language mode throughout and the app target must match, or `TaxStore`'s actor
isolation stops being checked at exactly the boundary where it matters.

- [ ] **Step 8: Launch it once and confirm it runs**

```bash
xcrun simctl boot "Relio Test Phone" || true
xcrun simctl install "Relio Test Phone" \
  "$(xcodebuild -project TaxTracker.xcodeproj -scheme TaxTracker -destination 'platform=iOS Simulator,name=Relio Test Phone' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')"
xcrun simctl launch "Relio Test Phone" my.relio.TaxTracker
xcrun simctl io "Relio Test Phone" screenshot /tmp/relio-launch.png
```

Expected: the app launches and the screenshot shows "Relio" and "Storage: local".
A build that links is not the same as an app that opens its data store — this proves
`TaxContainer.make` succeeds on a device.

- [ ] **Step 9: Commit**

```bash
git add project.yml Config/Signing.example.xcconfig App Scripts .gitignore Package.swift Sources/TaxPresentation
git commit -m "chore: generate the app project with XcodeGen and add the simulator build gate"
```

---

### Task 10: `YearContext` — one evaluation, shared by every screen

**Files:**
- Create: `Sources/TaxPresentation/YearContext.swift` (replaces the placeholder)
- Test: `Tests/TaxPresentationTests/YearContextTests.swift`

**Interfaces:**
- Consumes: `TaxStore.project(year:)`, `TaxStore.preferences()`,
  `TaxStore.savePreferences(_:)` from `TaxData`; `RuleSetLoading`, `evaluate`,
  `EvaluationResult` from `TaxKit`.
- Produces:
  - `@MainActor @Observable public final class YearContext` with `year`,
    `availableYears`, `result: EvaluationResult?`, `status: LoadStatus`,
    `load()`, `switchYear(to:)`, `reload()`.
  - `enum LoadStatus: Hashable, Sendable { case idle, loading, ready, unavailable(String) }`

**One evaluation per year, not one per screen.** `evaluate` walks the whole rulebook and
Home, Reliefs and the detail screens all need its output. Each holding its own copy would
mean three evaluations per year change, three chances to be looking at different numbers,
and a Compare screen later that disagrees with Home. `YearContext` owns the single
result; every view model in Tasks 11–17 reads from it.

**A year with no shipped rulebook is a state, not an error.** `availableYears` is
`[2023, 2024, 2025]`. A user who switches to 2026 must see "rules for 2026 aren't
available yet", with their entries intact underneath — not a crash, and not an empty
screen implying they have no data.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxPresentationTests/YearContextTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

/// Builders shared by every presentation suite.
enum PresentationFixture {

    static let epoch = Date(timeIntervalSince1970: 1_750_000_000)

    static func store() async throws -> TaxStore {
        let container = try TaxContainer.make(.inMemory)
        let store = TaxStore(modelContainer: container)
        await store.useClock { epoch }
        return store
    }

    /// A household with income, so `taxSaved` and `totalOpportunity` are non-nil.
    static func seedTypicalHousehold(_ store: TaxStore) async throws {
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        facts.maritalStatus = .married
        facts.spouseHasIncome = false
        facts.assessmentType = .separate
        facts.employmentType = .privateSector
        try await store.saveYearFacts(facts, for: 2025)

        for (code, ringgit) in [("LIFESTYLE", Decimal(1_700)),
                                ("MEDICAL_CHECKUP", Decimal(400)),
                                ("SSPN", Decimal(1_000))] {
            var draft = EntryDraft(id: UUID(), year: 2025,
                                   code: ReliefCode(code), amount: Money(ringgit: ringgit))
            draft.vendor = code
            _ = try await store.save(draft)
        }
    }

    @MainActor
    static func context(_ store: TaxStore, year: Int = 2025) -> YearContext {
        YearContext(store: store, loader: BundledRuleSetLoader(), year: year)
    }
}

@Suite("YearContext") @MainActor struct YearContextTests {

    @Test("loading evaluates the persisted year")
    func loadEvaluates() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)

        let context = PresentationFixture.context(store)
        #expect(context.status == .idle)
        await context.load()

        #expect(context.status == .ready)
        let result = try #require(context.result)
        #expect(result.yearOfAssessment == 2025)
        #expect(result.chargeableIncome != nil)
        #expect(result.assessment(for: ReliefCode("LIFESTYLE"))?.claimed == Money(ringgit: 1_700))
    }

    @Test("available years come from the loader")
    func availableYears() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store)
        await context.load()
        #expect(context.availableYears == [2023, 2024, 2025])
    }

    @Test("switching year re-evaluates against that year's rules")
    func switchingYear() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store)
        await context.load()

        await context.switchYear(to: 2023)
        #expect(context.year == 2023)
        #expect(context.status == .ready)
        // 2023 has no entries seeded, so nothing is claimed — but the automatic
        // individual relief still applies and the screen still has a number to show.
        #expect(context.result?.yearOfAssessment == 2023)
        #expect(context.result?.assessment(for: ReliefCode("LIFESTYLE"))?.claimed == Money.zero)
    }

    @Test("a year with no shipped rulebook is unavailable, not an error screen")
    func unshippedYear() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store)
        await context.switchYear(to: 2026)

        #expect(context.year == 2026)
        #expect(context.result == nil)
        guard case .unavailable(let message) = context.status else {
            Issue.record("expected .unavailable, got \(context.status)")
            return
        }
        // The user's entries are still there. A crash or a blank screen would imply
        // otherwise, and this is the state every January until the Budget ships.
        #expect(message.contains("2026"))
    }

    @Test("reloading picks up a write")
    func reloadSeesNewEntries() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store)
        await context.load()
        let before = try #require(context.result?.assessment(for: ReliefCode("SSPN"))?.claimed)

        var addition = EntryDraft(id: UUID(), year: 2025,
                                  code: ReliefCode("SSPN"), amount: Money(ringgit: 500))
        addition.vendor = "Extra deposit"
        _ = try await store.save(addition)
        await context.reload()

        let after = try #require(context.result?.assessment(for: ReliefCode("SSPN"))?.claimed)
        #expect(after == before + Money(ringgit: 500))
    }

    @Test("switching year remembers the choice for next launch")
    func lastViewedYearIsPersisted() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store)
        await context.load()
        await context.switchYear(to: 2024)

        #expect(try await store.preferences().lastViewedYear == 2024)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter YearContext`
Expected: FAIL — "cannot find 'YearContext' in scope".

- [ ] **Step 3: Write `YearContext`**

Replace `Sources/TaxPresentation/YearContext.swift`:

```swift
import Foundation
import Observation
import TaxKit
import TaxData

public enum LoadStatus: Hashable, Sendable {
    case idle
    case loading
    case ready
    /// The year has no shipped rulebook. The user's entries still exist.
    case unavailable(String)
}

/// The one evaluation every screen reads.
///
/// `evaluate` walks the whole rulebook, and Home, Reliefs and the detail screens all need
/// its output. Three screens each holding their own copy would mean three evaluations per
/// year change and three chances to disagree about the same number — which is precisely
/// the failure a tax app cannot have.
///
/// `@Observable` and `@MainActor`: this is view state. All the work happens inside the
/// `TaxStore` actor and only the finished value comes back here.
@MainActor
@Observable
public final class YearContext {

    public private(set) var year: Int
    public private(set) var availableYears: [Int]
    public private(set) var result: EvaluationResult?
    public private(set) var status: LoadStatus = .idle

    private let store: TaxStore
    private let loader: any RuleSetLoading

    public init(store: TaxStore, loader: any RuleSetLoading, year: Int) {
        self.store = store
        self.loader = loader
        self.year = year
        self.availableYears = loader.availableYears
    }

    public func load() async {
        status = .loading
        do {
            let ruleSet = try loader.ruleSet(for: year)
            let projected = try await store.project(year: year)
            result = evaluate(ruleSet: ruleSet,
                              year: projected.snapshot,
                              entries: projected.entries)
            status = .ready
        } catch is RuleSetLoadingError {
            // Not an error state. Every January until the Budget ships, the current year
            // has no rulebook, and the user's entries for it still exist and still matter.
            result = nil
            status = .unavailable("Rules for \(year) aren't available yet.")
        } catch {
            result = nil
            status = .unavailable("Could not load \(year): \(error.localizedDescription)")
        }
    }

    public func reload() async {
        await load()
    }

    public func switchYear(to newYear: Int) async {
        year = newYear
        await load()
        await rememberYear(newYear)
    }

    /// Launch resumes where the user left off. A failure here is not worth surfacing —
    /// the cost is opening on the wrong year once.
    private func rememberYear(_ newYear: Int) async {
        do {
            var preferences = try await store.preferences()
            preferences.lastViewedYear = newYear
            try await store.savePreferences(preferences)
        } catch {
            return
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter YearContext`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/TaxPresentation Tests/TaxPresentationTests
git commit -m "feat: add YearContext as the single evaluated-year state"
```

---

### Task 11: `HomeViewModel` — the headline, the prompts and the top three

**Files:**
- Create: `Sources/TaxPresentation/HomeViewModel.swift`
- Test: `Tests/TaxPresentationTests/HomeViewModelTests.swift`

**Interfaces:**
- Consumes: `YearContext` from Task 10; `TaxStore.entryDrafts(forYear:)`,
  `TaxStore.preferences()`.
- Produces:
  - `@MainActor @Observable public final class HomeViewModel`
  - `struct OpportunityRow: Hashable, Sendable, Identifiable` — `code`, `name`,
    `headroom`, `taxSaved`, `usedPercent`, `needsAnswer`.
  - `enum HeadlineKind { case taxSaved, relief }`
  - `struct HomePrompts: Hashable, Sendable` — `unansweredQuestionCount`,
    `unlockableRelief`, `claimsMissingDocuments`.

**The headline is tax, not relief.** Spec §11's mock reads "RM 2,616 / still claimable"
above rows of "RM 8,000 left → RM 1,520". The rows' left-hand figures already sum past
RM 10,000, so the headline cannot be relief headroom — it is the tax that headroom is
worth, which is exactly Plan 1's `EvaluationResult.totalOpportunity` (computed as one
calculation against combined headroom, because summing per-relief figures double-counts
the top band).

**With income off there is no tax figure, so the headline changes meaning and says so.**
`totalOpportunity` is `nil` without gross income. Spec §11 says the right-hand column
disappears and the layout is unchanged — so the headline falls back to total remaining
*relief*, and `headlineKind` tells the view which label to use. Showing a relief figure
under a "tax saved" label would be a straightforward lie about money.

**Ranking keys off eligibility and `taxSaved`, never `headroom` alone.** Carried forward
from Plan 1's final review: an `.ineligible` relief still reports `headroom` equal to its
cap while `allowed` is zero, so ranking on headroom would put reliefs the user cannot
claim at the top of the one screen that exists to tell them what to do next. Candidates
are filtered on `eligibility != .ineligible` first; only then does the sort consider
`taxSaved` (or `headroom`, when income is off and every `taxSaved` is nil). `.needsInfo`
reliefs stay in — Plan 1 settled that they are money the user may recover by answering
one question, and they render as a prompt rather than as a banked figure.

**`usedPercent` is integer arithmetic.** A progress bar needs a fraction and the package
bans `Double` outside charting. `allowed.sen * 100 / cap.sen` is exact enough for a
ten-segment bar and keeps the constraint intact.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxPresentationTests/HomeViewModelTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

@Suite("HomeViewModel") @MainActor struct HomeViewModelTests {

    static func model(_ store: TaxStore, year: Int = 2025) async -> HomeViewModel {
        let context = PresentationFixture.context(store, year: year)
        await context.load()
        let model = HomeViewModel(context: context, store: store)
        await model.refresh()
        return model
    }

    @Test("the headline is the tax the remaining headroom is worth")
    func headlineIsTax() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)

        #expect(model.headlineKind == .taxSaved)
        let expected = try #require(model.context.result?.totalOpportunity)
        #expect(model.headline == expected)
        #expect(model.headline > Money.zero)
    }

    @Test("with income unknown the headline becomes relief and says so")
    func headlineFallsBackToRelief() async throws {
        let store = try await PresentationFixture.store()
        // No gross income: every taxSaved is nil and totalOpportunity is nil.
        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("LIFESTYLE"), amount: Money(ringgit: 1_000))
        draft.vendor = "Popular"
        _ = try await store.save(draft)
        let model = await Self.model(store)

        // Showing a relief figure under a "tax saved" label would be a plain lie about
        // money, so the kind changes with the number.
        #expect(model.headlineKind == .relief)
        #expect(model.headline > Money.zero)
        #expect(model.context.result?.totalOpportunity == nil)
    }

    @Test("opportunities are the top three by tax saved, and the rest are counted")
    func topThreeByTaxSaved() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)

        #expect(model.opportunities.count <= 3)
        let saved = model.opportunities.compactMap(\.taxSaved)
        #expect(saved == saved.sorted(by: >), "highest ringgit recoverable first")
        #expect(model.remainingOpportunityCount >= 0)
    }

    @Test("an ineligible relief never appears, however large its headroom")
    func ineligibleIsExcluded() {
        // Tested directly against the ranking function rather than through a seeded
        // household. Verified during pre-flight: YA2025 yields 19 eligible, 5 needsInfo
        // and ZERO ineligible reliefs for a plain household, so a fixture-driven version
        // of this test could only ever pass by accident of what a Budget happens to say.
        //
        // An ineligible relief reports headroom equal to its cap while `allowed` is zero.
        // Ranking on headroom alone would put reliefs the user cannot claim at the top of
        // the one screen that exists to tell them what to do next.
        let ranked = HomeViewModel.rankedCandidates(in: Self.syntheticResult)
        #expect(ranked.map(\.code) == [ReliefCode("RICH"), ReliefCode("ASK")])
        #expect(!ranked.contains { $0.code == ReliefCode("REFUSED") })
    }

    @Test("a needsInfo relief stays in the ranking, rendered as a question")
    func needsInfoStaysRanked() {
        // Plan 1 settled this: a .needsInfo relief is money the user may recover by
        // answering one question, so excluding it would make the headline understate the
        // upside and bury the prompt.
        let ranked = HomeViewModel.rankedCandidates(in: Self.syntheticResult)
        let asked = try? #require(ranked.first { $0.code == ReliefCode("ASK") })
        #expect(asked??.needsAnswer == true)
    }

    /// Three reliefs with identical headroom and differing eligibility, so the filter and
    /// the ordering are both observable without depending on any shipped rulebook.
    static var syntheticResult: EvaluationResult {
        func assessment(_ code: String,
                        eligibility: Eligibility,
                        taxSaved: Money?) -> ReliefAssessment {
            ReliefAssessment(code: ReliefCode(code),
                             name: code.capitalized,
                             cap: Money(ringgit: 10_000),
                             claimed: .zero,
                             allowed: .zero,
                             headroom: Money(ringgit: 10_000),
                             eligibility: eligibility,
                             requirements: [],
                             taxSaved: taxSaved,
                             unverified: false,
                             sourceURL: URL(string: "https://www.hasil.gov.my/")!,
                             notes: nil,
                             children: [])
        }

        return EvaluationResult(
            yearOfAssessment: 2025,
            assessments: [
                assessment("REFUSED", eligibility: .ineligible(reasons: ["Not you"]),
                           taxSaved: Money(ringgit: 9_999)),
                assessment("ASK", eligibility: .needsInfo(questions: []),
                           taxSaved: Money(ringgit: 100)),
                assessment("RICH", eligibility: .eligible,
                           taxSaved: Money(ringgit: 500))
            ],
            unresolved: [],
            chargeableIncome: Money(ringgit: 100_000),
            estimatedTax: Money(ringgit: 10_000),
            totalOpportunity: Money(ringgit: 600))
    }

    @Test("ordering is stable across identical evaluations")
    func orderingIsDeterministic() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let first = await Self.model(store).opportunities.map(\.code)
        let second = await Self.model(store).opportunities.map(\.code)
        // Plan 1 shipped a bug where equal-valued rows reordered between launches. Ties
        // break on code here for the same reason.
        #expect(first == second)
    }

    @Test("unanswered questions are surfaced with what they are worth")
    func needsInfoPrompt() async throws {
        let store = try await PresentationFixture.store()
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        // Marital status left unanswered: spouse relief becomes .needsInfo, not refused.
        try await store.saveYearFacts(facts, for: 2025)
        let model = await Self.model(store)

        #expect(model.prompts.unansweredQuestionCount > 0)
        #expect(model.prompts.unlockableRelief > Money.zero)
    }

    @Test("claims missing a required document are counted")
    func missingDocumentPrompt() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        // LIFE_INSURANCE requires an insurance statement; this has no documents at all.
        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("LIFE_INSURANCE"), amount: Money(ringgit: 2_000))
        draft.vendor = "Great Eastern"
        _ = try await store.save(draft)
        let model = await Self.model(store)

        #expect(model.prompts.claimsMissingDocuments >= 1)
    }

    @Test("percent used is integer arithmetic and never divides by zero")
    func usedPercent() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)
        for row in model.opportunities {
            #expect(row.usedPercent >= 0)
            #expect(row.usedPercent <= 100)
        }
    }

    @Test("an empty first launch shows a number, not an error")
    func emptyStateHasAHeadline() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store)
        // Spec §11.5: empty states are the design. A blank or errored Home on first
        // launch is the worst possible first impression for a tracker.
        #expect(model.opportunities.isEmpty == false || model.headline >= Money.zero)
        #expect(model.context.status == .ready)
    }

    @Test("an unavailable year zeroes the screen without throwing")
    func unavailableYear() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store, year: 2026)
        await context.load()
        let model = HomeViewModel(context: context, store: store)
        await model.refresh()

        #expect(model.headline == Money.zero)
        #expect(model.opportunities.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter HomeViewModel`
Expected: FAIL — "cannot find 'HomeViewModel' in scope".

- [ ] **Step 3: Write `HomeViewModel`**

Create `Sources/TaxPresentation/HomeViewModel.swift`:

```swift
import Foundation
import Observation
import TaxKit
import TaxData

/// What the headline number means. The label changes with it, because a relief figure
/// shown under a "tax saved" heading is a lie about money.
public enum HeadlineKind: Hashable, Sendable {
    case taxSaved
    case relief
}

public struct OpportunityRow: Hashable, Sendable, Identifiable {
    public var code: ReliefCode
    public var name: String
    public var headroom: Money
    /// `nil` when income is unknown.
    public var taxSaved: Money?
    /// 0...100, integer arithmetic — the package bans `Double` outside charting.
    public var usedPercent: Int
    /// True for a `.needsInfo` relief, which renders as a question rather than a figure.
    public var needsAnswer: Bool

    public var id: ReliefCode { code }
}

public struct HomePrompts: Hashable, Sendable {
    public var unansweredQuestionCount: Int
    /// Relief that would become claimable if those questions were answered favourably.
    public var unlockableRelief: Money
    public var claimsMissingDocuments: Int

    public static let none = HomePrompts(unansweredQuestionCount: 0,
                                         unlockableRelief: .zero,
                                         claimsMissingDocuments: 0)
}

/// Spec §11: Home answers one question — how much is being left on the table.
@MainActor
@Observable
public final class HomeViewModel {

    public let context: YearContext
    public private(set) var headline: Money = .zero
    public private(set) var headlineKind: HeadlineKind = .relief
    public private(set) var opportunities: [OpportunityRow] = []
    public private(set) var remainingOpportunityCount: Int = 0
    public private(set) var prompts: HomePrompts = .none

    private let store: TaxStore

    public init(context: YearContext, store: TaxStore) {
        self.context = context
        self.store = store
    }

    public func refresh() async {
        guard let result = context.result else {
            headline = .zero
            headlineKind = .relief
            opportunities = []
            remainingOpportunityCount = 0
            prompts = .none
            return
        }

        let candidates = Self.rankedCandidates(in: result)

        if let total = result.totalOpportunity {
            headline = total
            headlineKind = .taxSaved
        } else {
            // No income, so no tax figure exists. Fall back to the relief still
            // available and let the view relabel.
            headline = candidates.reduce(Money.zero) { $0 + $1.headroom }
            headlineKind = .relief
        }

        opportunities = Array(candidates.prefix(3))
        remainingOpportunityCount = max(0, candidates.count - opportunities.count)
        prompts = await makePrompts(result)
    }

    /// Eligible-or-unanswered reliefs with room left, best first.
    ///
    /// The eligibility filter comes first and is not negotiable: an `.ineligible` relief
    /// still reports `headroom` equal to its cap while `allowed` is zero, so a list built
    /// on headroom alone advertises reliefs the user cannot claim.
    static func rankedCandidates(in result: EvaluationResult) -> [OpportunityRow] {
        result.assessments
            .filter { assessment in
                if case .ineligible = assessment.eligibility { return false }
                return assessment.headroom > .zero
            }
            .map { assessment in
                var needsAnswer = false
                if case .needsInfo = assessment.eligibility { needsAnswer = true }
                return OpportunityRow(code: assessment.code,
                                      name: assessment.name,
                                      headroom: assessment.headroom,
                                      taxSaved: assessment.taxSaved,
                                      usedPercent: Self.percentUsed(assessment),
                                      needsAnswer: needsAnswer)
            }
            .sorted { left, right in
                // Ties break on code. Plan 1 shipped a bug where equal-valued rows
                // reordered between launches; the fix is a total order, not a sort key.
                let leftValue = left.taxSaved ?? left.headroom
                let rightValue = right.taxSaved ?? right.headroom
                if leftValue != rightValue { return leftValue > rightValue }
                return left.code.rawValue < right.code.rawValue
            }
    }

    static func percentUsed(_ assessment: ReliefAssessment) -> Int {
        guard assessment.cap.sen > 0 else { return 0 }
        let percent = assessment.allowed.sen * 100 / assessment.cap.sen
        return min(100, max(0, percent))
    }

    private func makePrompts(_ result: EvaluationResult) async -> HomePrompts {
        var questions = 0
        var unlockable = Money.zero
        for assessment in result.assessments {
            if case .needsInfo(let asked) = assessment.eligibility {
                questions += asked.count
                unlockable = unlockable + assessment.headroom
            }
        }

        let missing = (try? await store.entryDrafts(forYear: context.year)
            .filter(\.needsDocument).count) ?? 0

        return HomePrompts(unansweredQuestionCount: questions,
                           unlockableRelief: unlockable,
                           claimsMissingDocuments: missing)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter HomeViewModel`
Expected: PASS — 11 tests.

**`EvaluationResult` and `ReliefAssessment` use memberwise initialisers.** If the
synthetic fixture will not compile because a property order or label differs, read
`Sources/TaxKit/Engine/ReliefAssessment.swift` and match the real signatures — do not
change the assertions to fit a broken fixture.

- [ ] **Step 5: Commit**

```bash
git add Sources/TaxPresentation Tests/TaxPresentationTests
git commit -m "feat: add HomeViewModel with eligibility-gated opportunity ranking"
```

---

### Task 12: `MoneyText`, the Home screen and the tab shell

**Files:**
- Create: `App/TaxTracker/Support/MoneyText.swift`
- Create: `App/TaxTracker/Home/HomeView.swift`
- Modify: `App/TaxTracker/RootView.swift` (replace the placeholder with the tab shell)

**Interfaces:**
- Consumes: `HomeViewModel`, `YearContext` from Tasks 10–11.
- Produces: `MoneyText`, `HomeView`, the three-tab `RootView`.

**Views hold no logic.** Everything on this screen was decided and tested in Task 11.
`HomeView` reads `model.headline`, `model.opportunities` and `model.prompts` and lays
them out. If a future change needs an `if` about *which* relief or *how much*, it belongs
in the view model where `swift test` can see it.

**`MoneyText` is the only place an amount becomes a View.** Global constraint: one
formatter, and interpolating an amount into user-facing text anywhere else is a defect.
Funnelling it through one view makes that greppable, and gives `.monospacedDigit()` — spec
§11.2 requires figures not jitter while animating — exactly one home.

**Documents and Ask are placeholder tabs.** Spec §11 has three tabs; their contents are
later plans. An empty tab with a one-line "coming in a later release" is honest. Hiding
them would mean rebuilding the shell later.

- [ ] **Step 1: Write `MoneyText`**

Create `App/TaxTracker/Support/MoneyText.swift`:

```swift
import SwiftUI
import TaxKit

/// The only place a `Money` becomes a `View`.
///
/// Global constraint: one formatter, and interpolating an amount into user-facing text
/// anywhere else is a defect. Routing every amount through one view makes that a
/// one-line grep, and gives `.monospacedDigit()` a single home — spec §11.2 requires
/// figures not jitter while a value animates.
struct MoneyText: View {
    let amount: Money
    var font: Font = .body
    var weight: Font.Weight = .regular

    var body: some View {
        Text(amount.formatted())
            .font(font.weight(weight))
            .monospacedDigit()
    }
}
```

- [ ] **Step 2: Write `HomeView`**

Create `App/TaxTracker/Home/HomeView.swift`:

```swift
import SwiftUI
import TaxKit
import TaxPresentation

struct HomeView: View {

    @Bindable var model: HomeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                headline
                prompts
                opportunities
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.refresh() }
    }

    // The only large number on the screen. Spec §11.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            MoneyText(amount: model.headline, font: .system(size: 44), weight: .bold)
                .contentTransition(.numericText())
            Text(model.headlineKind == .taxSaved ? "in tax still claimable" : "of relief still claimable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var prompts: some View {
        VStack(spacing: 10) {
            if model.prompts.unansweredQuestionCount > 0 {
                promptRow(
                    systemImage: "questionmark.circle",
                    title: model.prompts.unansweredQuestionCount == 1
                        ? "Answer 1 question"
                        : "Answer \(model.prompts.unansweredQuestionCount) questions",
                    trailing: model.prompts.unlockableRelief)
            }
            if model.prompts.claimsMissingDocuments > 0 {
                promptRow(
                    systemImage: "doc.viewfinder",
                    title: model.prompts.claimsMissingDocuments == 1
                        ? "1 claim needs a document"
                        : "\(model.prompts.claimsMissingDocuments) claims need documents",
                    trailing: nil)
            }
        }
    }

    private func promptRow(systemImage: String, title: String, trailing: Money?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
            Text(title)
            Spacer()
            if let trailing {
                HStack(spacing: 4) {
                    Text("unlock")
                    MoneyText(amount: trailing, weight: .semibold)
                }
                .font(.subheadline)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var opportunities: some View {
        if model.opportunities.isEmpty {
            // Spec §11.5: empty states are the design, not an afterthought.
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing logged yet")
                    .font(.headline)
                Text("Add your first receipt and Relio will show what it is worth.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Biggest opportunities")
                    .font(.headline)
                ForEach(model.opportunities) { row in
                    OpportunityRowView(row: row)
                }
                if model.remainingOpportunityCount > 0 {
                    Text("See all \(model.remainingOpportunityCount + model.opportunities.count)")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

struct OpportunityRowView: View {
    let row: OpportunityRow

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.name)
                ProgressView(value: Double(row.usedPercent), total: 100)
                    .tint(.accentColor)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(amount: row.headroom, font: .subheadline, weight: .semibold)
                if let saved = row.taxSaved {
                    HStack(spacing: 2) {
                        Text("→")
                        MoneyText(amount: saved, font: .caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        // Spec §11.8: VoiceOver reads the amounts, never "68 percent".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var label = "\(row.name), \(row.headroom.formatted()) still claimable"
        if let saved = row.taxSaved {
            label += ", worth \(saved.formatted()) in tax"
        }
        if row.needsAnswer {
            label += ", needs an answer first"
        }
        return label
    }
}
```

**`ProgressView(value: Double(row.usedPercent), total: 100)` is the one permitted
`Double`.** It is a SwiftUI API requirement at the render boundary, not a calculation —
the percentage itself was computed as an `Int` in Task 11. Do not let a `Double` travel
back up into the view model.

- [ ] **Step 3: Write the tab shell**

Replace `App/TaxTracker/RootView.swift`:

```swift
import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

struct RootView: View {

    let store: TaxStore
    @State private var context: YearContext
    @State private var home: HomeViewModel

    init(store: TaxStore) {
        self.store = store
        let context = YearContext(store: store,
                                  loader: BundledRuleSetLoader(),
                                  year: BundledRuleSetLoader().availableYears.last ?? 2025)
        _context = State(initialValue: context)
        _home = State(initialValue: HomeViewModel(context: context, store: store))
    }

    var body: some View {
        TabView {
            NavigationStack {
                content
                    .navigationTitle("YA \(String(context.year))")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Home", systemImage: "house") }

            NavigationStack {
                ContentUnavailableView("Documents",
                                       systemImage: "doc.text",
                                       description: Text("Receipt capture arrives in a later release."))
            }
            .tabItem { Label("Docs", systemImage: "doc.text") }

            NavigationStack {
                ContentUnavailableView("Ask",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("The on-device assistant arrives in a later release."))
            }
            .tabItem { Label("Ask", systemImage: "bubble.left.and.bubble.right") }
        }
        .task {
            await context.load()
            await home.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch context.status {
        case .idle, .loading:
            ProgressView()
        case .ready:
            HomeView(model: home)
        case .unavailable(let message):
            // The user's entries still exist. Saying so matters — a blank screen here
            // reads as data loss.
            ContentUnavailableView("No rules for \(String(context.year))",
                                   systemImage: "calendar.badge.exclamationmark",
                                   description: Text(message))
        }
    }
}
```

`String(context.year)` rather than `\(context.year)` throughout: a bare `Int`
interpolation renders `2,025` under some locales. Years are not quantities.

- [ ] **Step 4: Build and screenshot**

Run: `./Scripts/build-app.sh`
Expected: "Build succeeded."

Then launch and capture, as in Task 9 Step 8. Expected: an empty-state Home reading
"RM 0.00 / of relief still claimable" and "Nothing logged yet", with three tabs.

- [ ] **Step 5: Run the whole suite and commit**

Run: `swift test`
Expected: PASS, no regressions.

```bash
git add App
git commit -m "feat: add the Home screen, the tab shell and the single money view"
```

---

### Task 13: `ReliefsListViewModel` and `ReliefDetailViewModel`

**Files:**
- Create: `Sources/TaxPresentation/ReliefsListViewModel.swift`
- Create: `Sources/TaxPresentation/ReliefDetailViewModel.swift`
- Test: `Tests/TaxPresentationTests/ReliefsViewModelTests.swift`

**Interfaces:**
- Consumes: `YearContext`, `TaxStore.entryDrafts(forYear:)`.
- Produces:
  - `@MainActor @Observable public final class ReliefsListViewModel` — `sections`,
    `searchText`, `refresh()`.
  - `struct ReliefSection: Hashable, Sendable, Identifiable` — `title`, `rows`.
  - `struct ReliefRow: Hashable, Sendable, Identifiable` — `code`, `name`, `cap`,
    `allowed`, `headroom`, `usedPercent`, `state`.
  - `enum ReliefRowState { case claimable, needsAnswer, unavailable, exhausted }`
  - `@MainActor @Observable public final class ReliefDetailViewModel` — `assessment`,
    `entries`, `requirements`, `sourceURL`, `subLimits`, `refresh()`.

**Three sections, in a fixed order: `Needs an answer`, `Still claimable`, `Fully
claimed`.** Alphabetical order would bury the two groups the user can act on. `unavailable`
reliefs go in a fourth section, `Not applicable to you`, kept last and collapsed — they
are shown rather than hidden because "why can't I claim X" is one of spec §10's seeded
assistant prompts, and a relief the user cannot find is a question they cannot ask.

**The detail screen shows `claimed` and `allowed` separately.** Plan 1 made them distinct
for a reason: a parent relief's `claimed` is the raw sum a user typed and `allowed` is
what LHDN would permit after caps and sub-limits bind. Showing only `allowed` would hide
that a claim was trimmed; showing only `claimed` would overstate. Both, labelled.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxPresentationTests/ReliefsViewModelTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

@Suite("ReliefsListViewModel") @MainActor struct ReliefsListViewModelTests {

    static func model(_ store: TaxStore) async -> ReliefsListViewModel {
        let context = PresentationFixture.context(store)
        await context.load()
        let model = ReliefsListViewModel(context: context)
        model.refresh()
        return model
    }

    @Test("sections appear in action order, not alphabetical order")
    func sectionOrder() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)

        let titles = model.sections.map(\.title)
        let expected = ["Needs an answer", "Still claimable", "Fully claimed", "Not applicable to you"]
        // Alphabetical order would bury the two groups the user can act on.
        #expect(titles == expected.filter(titles.contains))
        #expect(titles == titles.sorted { expected.firstIndex(of: $0)! < expected.firstIndex(of: $1)! })
    }

    @Test("every top-level relief in the year appears exactly once")
    func everyReliefAppears() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)

        let listed = model.sections.flatMap(\.rows).map(\.code)
        let expected = try #require(model.context.result).assessments.map(\.code)
        #expect(Set(listed) == Set(expected))
        #expect(listed.count == expected.count, "no relief listed twice")
    }

    @Test("a relief with no room left is fully claimed, not still claimable")
    func exhaustedReliefIsSeparated() async throws {
        let store = try await PresentationFixture.store()
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        try await store.saveYearFacts(facts, for: 2025)
        // Well past the RM 2,500 lifestyle cap.
        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("LIFESTYLE"), amount: Money(ringgit: 9_000))
        draft.vendor = "Popular"
        _ = try await store.save(draft)
        let model = await Self.model(store)

        let row = try #require(model.sections.flatMap(\.rows).first { $0.code == ReliefCode("LIFESTYLE") })
        #expect(row.state == .exhausted)
        #expect(row.usedPercent == 100)
        #expect(row.headroom == Money.zero)
    }

    @Test("search filters by name and by code")
    func search() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)

        model.searchText = "lifestyle"
        model.refresh()
        let byName = model.sections.flatMap(\.rows).map(\.code)
        #expect(byName.contains(ReliefCode("LIFESTYLE")))
        #expect(byName.allSatisfy {
            $0.rawValue.lowercased().contains("lifestyle")
                || (model.context.result?.assessment(for: $0)?.name.lowercased().contains("lifestyle") ?? false)
        })

        model.searchText = ""
        model.refresh()
        #expect(model.sections.flatMap(\.rows).count > byName.count)
    }

    @Test("an unavailable year yields no sections and does not throw")
    func unavailableYear() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store, year: 2026)
        await context.load()
        let model = ReliefsListViewModel(context: context)
        model.refresh()
        #expect(model.sections.isEmpty)
    }
}

@Suite("ReliefDetailViewModel") @MainActor struct ReliefDetailViewModelTests {

    @Test("detail shows claimed and allowed separately when a cap binds")
    func claimedAndAllowedDiffer() async throws {
        let store = try await PresentationFixture.store()
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        try await store.saveYearFacts(facts, for: 2025)
        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("LIFESTYLE"), amount: Money(ringgit: 9_000))
        draft.vendor = "Popular"
        _ = try await store.save(draft)

        let context = PresentationFixture.context(store)
        await context.load()
        let model = ReliefDetailViewModel(context: context, store: store, code: ReliefCode("LIFESTYLE"))
        await model.refresh()

        let assessment = try #require(model.assessment)
        // Showing only `allowed` hides that the claim was trimmed; showing only
        // `claimed` overstates what LHDN would permit. The screen shows both.
        #expect(assessment.claimed == Money(ringgit: 9_000))
        #expect(assessment.allowed < assessment.claimed)
    }

    @Test("detail lists only this relief's entries")
    func entriesAreScoped() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store)
        await context.load()
        let model = ReliefDetailViewModel(context: context, store: store, code: ReliefCode("LIFESTYLE"))
        await model.refresh()

        #expect(!model.entries.isEmpty)
        #expect(model.entries.allSatisfy { $0.code == ReliefCode("LIFESTYLE") })
    }

    @Test("detail surfaces the LHDN source and any sub-limits")
    func sourceAndSubLimits() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store)
        await context.load()
        let model = ReliefDetailViewModel(context: context, store: store,
                                          code: ReliefCode("MEDICAL_SERIOUS"))
        await model.refresh()

        // Spec success criterion 2: every figure traces to a rulebook value carrying an
        // LHDN source URL, and the detail screen is where the user sees it.
        #expect(model.sourceURL?.host()?.contains("hasil.gov.my") == true)
        #expect(!model.subLimits.isEmpty, "MEDICAL_SERIOUS has sub-limits in YA2025")
    }

    @Test("an unknown code yields an empty screen rather than a crash")
    func unknownCode() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store)
        await context.load()
        let model = ReliefDetailViewModel(context: context, store: store,
                                          code: ReliefCode("NOT_A_REAL_CODE"))
        await model.refresh()
        #expect(model.assessment == nil)
        #expect(model.entries.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter Relief`
Expected: FAIL — "cannot find 'ReliefsListViewModel' in scope".

- [ ] **Step 3: Write the list view model**

Create `Sources/TaxPresentation/ReliefsListViewModel.swift`:

```swift
import Foundation
import Observation
import TaxKit
import TaxData

public enum ReliefRowState: Hashable, Sendable {
    case needsAnswer
    case claimable
    case exhausted
    case unavailable
}

public struct ReliefRow: Hashable, Sendable, Identifiable {
    public var code: ReliefCode
    public var name: String
    public var cap: Money
    public var allowed: Money
    public var headroom: Money
    public var usedPercent: Int
    public var state: ReliefRowState

    public var id: ReliefCode { code }
}

public struct ReliefSection: Hashable, Sendable, Identifiable {
    public var title: String
    public var rows: [ReliefRow]
    public var id: String { title }
}

@MainActor
@Observable
public final class ReliefsListViewModel {

    public let context: YearContext
    public var searchText: String = ""
    public private(set) var sections: [ReliefSection] = []

    public init(context: YearContext) {
        self.context = context
    }

    /// Fixed section order, chosen so the two groups the user can act on come first.
    /// Alphabetical order would bury them.
    private static let sectionOrder: [(String, ReliefRowState)] = [
        ("Needs an answer", .needsAnswer),
        ("Still claimable", .claimable),
        ("Fully claimed", .exhausted),
        ("Not applicable to you", .unavailable)
    ]

    public func refresh() {
        guard let result = context.result else {
            sections = []
            return
        }

        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = result.assessments
            .filter { needle.isEmpty
                || $0.name.lowercased().contains(needle)
                || $0.code.rawValue.lowercased().contains(needle) }
            .map(Self.row(from:))

        sections = Self.sectionOrder.compactMap { title, state in
            let matching = rows
                .filter { $0.state == state }
                .sorted { left, right in
                    if left.headroom != right.headroom { return left.headroom > right.headroom }
                    return left.code.rawValue < right.code.rawValue
                }
            return matching.isEmpty ? nil : ReliefSection(title: title, rows: matching)
        }
    }

    static func row(from assessment: ReliefAssessment) -> ReliefRow {
        let state: ReliefRowState
        switch assessment.eligibility {
        case .ineligible:
            state = .unavailable
        case .needsInfo:
            state = .needsAnswer
        case .eligible:
            state = assessment.headroom > .zero ? .claimable : .exhausted
        }

        return ReliefRow(code: assessment.code,
                         name: assessment.name,
                         cap: assessment.cap,
                         allowed: assessment.allowed,
                         headroom: assessment.headroom,
                         usedPercent: HomeViewModel.percentUsed(assessment),
                         state: state)
    }
}
```

- [ ] **Step 4: Write the detail view model**

Create `Sources/TaxPresentation/ReliefDetailViewModel.swift`:

```swift
import Foundation
import Observation
import TaxKit
import TaxData

@MainActor
@Observable
public final class ReliefDetailViewModel {

    public let code: ReliefCode
    public private(set) var assessment: ReliefAssessment?
    public private(set) var entries: [EntryDraft] = []
    public private(set) var subLimits: [ReliefAssessment] = []
    public private(set) var requirements: [RequirementCheck] = []
    public private(set) var sourceURL: URL?
    public private(set) var notes: String?

    private let context: YearContext
    private let store: TaxStore

    public init(context: YearContext, store: TaxStore, code: ReliefCode) {
        self.context = context
        self.store = store
        self.code = code
    }

    public func refresh() async {
        guard let found = context.result?.assessment(for: code) else {
            assessment = nil
            entries = []
            subLimits = []
            requirements = []
            sourceURL = nil
            notes = nil
            return
        }

        assessment = found
        subLimits = found.children
        requirements = found.requirements
        sourceURL = found.sourceURL
        notes = found.notes

        // A sub-limit's entries belong to it, not to the parent, so the parent screen
        // lists only its own — the children are rendered as their own rows.
        let all = (try? await store.entryDrafts(forYear: context.year)) ?? []
        entries = all
            .filter { $0.code == code }
            .sorted { left, right in
                if left.spentOn != right.spentOn {
                    return (left.spentOn ?? .distantPast) > (right.spentOn ?? .distantPast)
                }
                return left.id.uuidString < right.id.uuidString
            }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter Relief`
Expected: PASS — 9 tests in 2 suites.

**`HomeViewModel.percentUsed` is `static` and internal**; the list view model is in the
same target so it resolves. If Task 11 left it `private`, widen it to `static func` with
no access modifier rather than duplicating the arithmetic.

- [ ] **Step 6: Commit**

```bash
git add Sources/TaxPresentation Tests/TaxPresentationTests
git commit -m "feat: add the reliefs list and detail view models"
```

---

### Task 14: The Reliefs list and detail screens

**Files:**
- Create: `App/TaxTracker/Reliefs/ReliefsListView.swift`
- Create: `App/TaxTracker/Reliefs/ReliefDetailView.swift`
- Modify: `App/TaxTracker/Home/HomeView.swift` (make "See all" a navigation link)
- Modify: `App/TaxTracker/RootView.swift` (own the navigation path)

**Interfaces:**
- Consumes: `ReliefsListViewModel`, `ReliefDetailViewModel` from Task 13.
- Produces: `ReliefsListView`, `ReliefDetailView`, and a `NavigationStack` path typed on
  `ReliefCode`.

**Navigation is typed on `ReliefCode`.** `navigationDestination(for: ReliefCode.self)`
rather than a boolean or a bound optional: the detail screen is reachable from Home's
top-three rows, from the full list, and later from an assistant `ProposedAction` card and
a widget deep link. One destination declaration serves all of them.

- [ ] **Step 1: Write the list screen**

Create `App/TaxTracker/Reliefs/ReliefsListView.swift`:

```swift
import SwiftUI
import TaxKit
import TaxPresentation

struct ReliefsListView: View {

    @Bindable var model: ReliefsListViewModel

    var body: some View {
        List {
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        NavigationLink(value: row.code) {
                            ReliefRowView(row: row)
                        }
                    }
                }
            }
        }
        .navigationTitle("Reliefs")
        .searchable(text: $model.searchText, prompt: "Search reliefs")
        .onChange(of: model.searchText) { model.refresh() }
        .onAppear { model.refresh() }
        .overlay {
            if model.sections.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }
}

struct ReliefRowView: View {
    let row: ReliefRow

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.name)
                if row.state == .claimable || row.state == .exhausted {
                    ProgressView(value: Double(row.usedPercent), total: 100)
                        .tint(row.state == .exhausted ? .secondary : .accentColor)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .claimable:
            MoneyText(amount: row.headroom, font: .subheadline, weight: .semibold)
        case .exhausted:
            Text("Full").font(.subheadline).foregroundStyle(.secondary)
        case .needsAnswer:
            Image(systemName: "questionmark.circle").foregroundStyle(.tint)
        case .unavailable:
            Text("N/A").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// Spec §11.8: "Lifestyle, RM 1,700 of RM 2,500 used", never "68 percent".
    private var accessibilityLabel: String {
        switch row.state {
        case .claimable, .exhausted:
            return "\(row.name), \(row.allowed.formatted()) of \(row.cap.formatted()) used"
        case .needsAnswer:
            return "\(row.name), needs an answer before it can be claimed"
        case .unavailable:
            return "\(row.name), not applicable to you"
        }
    }
}
```

- [ ] **Step 2: Write the detail screen**

Create `App/TaxTracker/Reliefs/ReliefDetailView.swift`:

```swift
import SwiftUI
import TaxKit
import TaxPresentation

struct ReliefDetailView: View {

    @Bindable var model: ReliefDetailViewModel

    var body: some View {
        List {
            if let assessment = model.assessment {
                Section {
                    labelled("Cap", assessment.cap)
                    labelled("Claimed", assessment.claimed)
                    // Both figures, labelled. `claimed` is what the user entered;
                    // `allowed` is what LHDN would permit once caps bind. Showing one
                    // without the other either hides a trim or overstates the claim.
                    labelled("Allowed", assessment.allowed)
                    labelled("Still claimable", assessment.headroom)
                    if let saved = assessment.taxSaved {
                        labelled("Tax saved", saved)
                    }
                }

                if case .needsInfo(let questions) = assessment.eligibility {
                    Section("To claim this") {
                        ForEach(questions, id: \.self) { question in
                            Label(String(describing: question), systemImage: "questionmark.circle")
                        }
                    }
                }

                if case .ineligible(let reasons) = assessment.eligibility {
                    Section("Why you cannot claim this") {
                        ForEach(reasons, id: \.self) { reason in
                            Label(reason, systemImage: "xmark.circle")
                        }
                    }
                }

                if !model.subLimits.isEmpty {
                    Section("Within this relief") {
                        ForEach(model.subLimits) { child in
                            NavigationLink(value: child.code) {
                                HStack {
                                    Text(child.name)
                                    Spacer()
                                    MoneyText(amount: child.headroom, font: .subheadline)
                                }
                            }
                        }
                    }
                }

                if !model.requirements.isEmpty {
                    Section("Documents") {
                        ForEach(model.requirements, id: \.kind) { check in
                            Label(String(describing: check.kind),
                                  systemImage: check.isSatisfied ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(check.isSatisfied ? .primary : .orange)
                        }
                    }
                }

                Section("Entries") {
                    if model.entries.isEmpty {
                        Text("Nothing logged for this relief yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.entries) { entry in
                            NavigationLink(value: EntryRoute(entryID: entry.id)) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(entry.vendor.isEmpty ? "Untitled" : entry.vendor)
                                        if entry.needsDocument {
                                            Text("Missing a document")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer()
                                    MoneyText(amount: entry.amount, font: .subheadline)
                                }
                            }
                        }
                    }
                }

                if let url = model.sourceURL {
                    Section {
                        Link("LHDN source", destination: url)
                        if let notes = model.notes {
                            Text(notes).font(.footnote).foregroundStyle(.secondary)
                        }
                    } footer: {
                        // Spec §13: the user must never mistake an estimate for advice.
                        Text("Estimate only. Verify with LHDN before you file.")
                    }
                }
            } else {
                ContentUnavailableView("Relief not found",
                                       systemImage: "questionmark.folder",
                                       description: Text("This relief is not part of the \(String(model.yearOfAssessment)) rulebook."))
            }
        }
        .navigationTitle(model.assessment?.name ?? "Relief")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
    }

    private func labelled(_ title: String, _ amount: Money) -> some View {
        HStack {
            Text(title)
            Spacer()
            MoneyText(amount: amount, font: .body, weight: .medium)
        }
    }
}

```

`EntryRoute` is referenced here but declared in `Support/Routes.swift` (Step 3).

`model.yearOfAssessment` does not exist yet — add it to `ReliefDetailViewModel`:

```swift
    public var yearOfAssessment: Int { context.year }
```

`context` stays `private let`: the computed property is declared on the same type, where
private is already visible.

- [ ] **Step 3: Wire navigation into the shell**

In `App/TaxTracker/Home/HomeView.swift`, replace the plain "See all" `Text` with:

```swift
                if model.remainingOpportunityCount > 0 {
                    NavigationLink(value: ReliefsRoute()) {
                        Text("See all \(model.remainingOpportunityCount + model.opportunities.count)")
                            .font(.subheadline)
                    }
                }
```

and make each opportunity row tappable:

```swift
                ForEach(model.opportunities) { row in
                    NavigationLink(value: row.code) {
                        OpportunityRowView(row: row)
                    }
                    .buttonStyle(.plain)
                }
```

Create `App/TaxTracker/Support/Routes.swift`, and move `EntryRoute` here out of
`ReliefDetailView.swift` so both navigation values have one home:

```swift
import Foundation

/// Navigation value for the full reliefs list.
struct ReliefsRoute: Hashable {}

```

`EntryRoute` is referenced here but declared in `Support/Routes.swift` (Step 3).

In `RootView`, attach the destinations to the Home `NavigationStack`:

```swift
            NavigationStack {
                content
                    .navigationTitle("YA \(String(context.year))")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: ReliefsRoute.self) { _ in
                        ReliefsListView(model: ReliefsListViewModel(context: context))
                    }
                    .navigationDestination(for: ReliefCode.self) { code in
                        ReliefDetailView(model: ReliefDetailViewModel(context: context,
                                                                      store: store,
                                                                      code: code))
                    }
            }
```

`ReliefCode` is already `Hashable`, so it works as a navigation value with no adapter.

- [ ] **Step 4: Build, launch and screenshot**

Run: `./Scripts/build-app.sh`
Expected: "Build succeeded."

Launch as in Task 9 Step 8. With an empty store the list shows only automatic reliefs
under "Still claimable" — the individual relief among them. Tap into one and confirm the
detail screen shows a cap, an LHDN link and the estimate disclaimer.

- [ ] **Step 5: Commit**

```bash
git add App Sources/TaxPresentation
git commit -m "feat: add the reliefs list and detail screens with typed navigation"
```

---

### Task 15: `EntryEditorViewModel` — create, edit, delete, undo

**Files:**
- Create: `Sources/TaxPresentation/MoneyParsing.swift`
- Create: `Sources/TaxPresentation/EntryEditorViewModel.swift`
- Test: `Tests/TaxPresentationTests/EntryEditorViewModelTests.swift`

**Interfaces:**
- Consumes: `YearContext`, `TaxStore.save(_:)`, `softDeleteEntry(id:)`,
  `restoreEntry(id:)`, `entryDrafts(forYear:)`.
- Produces:
  - `enum MoneyParsing { static func money(from text: String) -> Money? }`
  - `@MainActor @Observable public final class EntryEditorViewModel`
  - `struct ReliefOption: Hashable, Sendable, Identifiable`,
    `struct DependentOption: Hashable, Sendable, Identifiable`

**Automatic reliefs are not offered in the picker.** Plan 1 parked this: "an automatic
relief overwrites any user-entered amount with the cap and the discarded figure goes
nowhere — no unresolved entry, no note. Contradicts the never-silently-drop ethos.
Revisit in Plan 2." This is the revisit. An automatic relief is granted in full from
household facts — the individual relief, the child reliefs, the disabled reliefs — so an
amount logged against one is discarded by the evaluator with no trace. Rather than
teaching the engine to report a discard, the editor does not let the entry be created:
those codes are filtered out of `availableCodes`, and an entry that somehow already
exists against one opens read-only with an explanation. The user is directed to the
household facts, which is where that relief is actually controlled.

**A claim's claimant comes from the rulebook, not from a default.** Four manually-loggable
YA2025 reliefs carry a `.claimant(in:)` predicate: PARENTS_MEDICAL (parent, grandparent),
MEDICAL_SERIOUS (child, spouse), LIFESTYLE (child, spouse) and LIFESTYLE_SPORTS (child,
parent, spouse). **PARENTS_MEDICAL does not admit `.individual` at all**, so an entry saved
with the default claimant is refused outright by the engine — a silent RM 8,000 loss on a
claim the user entered correctly. The editor therefore offers a claimant picker populated
from the rule's admitted set, and refuses to save when the rule excludes the current
choice.

**There is no per-dependent relief to require a dependent for.** Every `.perDependent`
relief in every shipped year is also `automatic: true` (the five CHILD_* codes), and
automatic reliefs are filtered out of the picker, so a cap-kind-derived "requires a
dependent" flag would be unreachable code. The dependent field is an *optional annotation*
instead, offered for reliefs that admit a child, parent or grandparent claimant. The engine
ignores `dependentID` for a fixed cap; this is for the user's own record.

**A same-session duplicate warns at entry time.** Spec §6.5 catches duplicates here, one
layer before the reconciliation sweep. It warns rather than blocks: two identical receipts
from the same shop on the same day are unusual but real, and refusing the second would
make the app wrong about the user's own money.

**Money is parsed without `Double`.** `Decimal(string:locale:)` against a POSIX locale
after stripping `RM`, spaces and thousands separators. `Double(text)` would introduce
exactly the representation error `Money` exists to prevent, at the one point where the
user's own figure enters the system.

**Zero and negative amounts are rejected, and that has a known cost.** LHDN defines SSPN
relief as a *net* deposit, so a withdrawal-heavy year is legitimately negative — Plan 1
found this and clamped the engine in both directions to handle it. This editor cannot
express it: there is no "this is a net withdrawal" affordance, and treating an unmarked
negative as intentional would let a typo silently reduce someone's relief. **Record in
the ledger**: a negative net SSPN year cannot be entered through this UI. The engine
handles it correctly if the value arrives another way, and the affordance belongs with
the SSPN-specific UI a later plan builds.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxPresentationTests/EntryEditorViewModelTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

@Suite("Money parsing") struct MoneyParsingTests {

    @Test("common shapes of a typed amount parse exactly")
    func parsesTypedAmounts() {
        #expect(MoneyParsing.money(from: "1820") == Money(ringgit: 1_820))
        #expect(MoneyParsing.money(from: "1820.50") == Money(sen: 182_050))
        #expect(MoneyParsing.money(from: "1,820.50") == Money(sen: 182_050))
        #expect(MoneyParsing.money(from: "RM 1,820.50") == Money(sen: 182_050))
        #expect(MoneyParsing.money(from: "  1820.5  ") == Money(sen: 182_050))
    }

    @Test("a third decimal place is rounded half-up, not truncated")
    func roundsToSen() {
        // Money(ringgit:) rounds half-up at the boundary; this pins that the parser
        // hands it a Decimal rather than doing its own lossy conversion.
        #expect(MoneyParsing.money(from: "10.005") == Money(sen: 1_001))
        #expect(MoneyParsing.money(from: "10.004") == Money(sen: 1_000))
    }

    @Test("nonsense does not parse")
    func rejectsNonsense() {
        #expect(MoneyParsing.money(from: "") == nil)
        #expect(MoneyParsing.money(from: "abc") == nil)
        #expect(MoneyParsing.money(from: "RM") == nil)
        #expect(MoneyParsing.money(from: "1.2.3") == nil)
    }
}

@Suite("EntryEditorViewModel") @MainActor struct EntryEditorViewModelTests {

    static func editor(_ store: TaxStore, editing id: UUID? = nil) async -> EntryEditorViewModel {
        let context = PresentationFixture.context(store)
        await context.load()
        let model = EntryEditorViewModel(context: context, store: store, editing: id)
        await model.load()
        return model
    }

    @Test("a new entry saves and appears in the year")
    func createsAnEntry() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.editor(store)

        model.selectedCode = ReliefCode("LIFESTYLE")
        model.amountText = "320.50"
        model.vendor = "Kinokuniya"
        #expect(model.canSave)

        #expect(await model.save())
        let saved = try await store.entryDrafts(forYear: 2025)
            .first { $0.vendor == "Kinokuniya" }
        #expect(saved?.amount == Money(sen: 32_050))
        #expect(saved?.code == ReliefCode("LIFESTYLE"))
    }

    @Test("editing an existing entry updates it in place")
    func editsInPlace() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let existing = try #require(try await store.entryDrafts(forYear: 2025).first)

        let model = await Self.editor(store, editing: existing.id)
        #expect(model.selectedCode == existing.code)
        #expect(MoneyParsing.money(from: model.amountText) == existing.amount)

        let countBefore = try await store.entryDrafts(forYear: 2025).count
        model.amountText = "999"
        #expect(await model.save())

        let after = try await store.entryDrafts(forYear: 2025)
        #expect(after.count == countBefore, "editing must not insert a second row")
        #expect(after.first { $0.id == existing.id }?.amount == Money(ringgit: 999))
    }

    @Test("automatic reliefs are not offered")
    func automaticRelievesAreFilteredOut() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.editor(store)

        let offered = Set(model.availableCodes.map(\.code))
        // An amount logged against an automatic relief is silently discarded by the
        // evaluator, which grants the full cap from household facts instead. Plan 1
        // parked this; the fix is to make the entry impossible to create.
        #expect(!offered.contains(ReliefCode("SELF_AND_DEPENDENTS")))
        #expect(!offered.isEmpty)

        let ruleSet = try BundledRuleSetLoader().ruleSet(for: 2025)
        for rule in ruleSet.allReliefs where rule.automatic {
            #expect(!offered.contains(rule.code), "\(rule.code) is automatic and must not be offered")
        }
    }

    @Test("an entry that already exists against an automatic relief opens read-only")
    func existingAutomaticEntryIsReadOnly() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("SELF_AND_DEPENDENTS"),
                               amount: Money(ringgit: 9_000))
        draft.vendor = "Imported"
        let id = try await store.save(draft)

        let model = await Self.editor(store, editing: id)
        #expect(model.isReadOnly)
        #expect(model.readOnlyReason != nil)
        #expect(!model.canSave)
    }

    @Test("an invalid amount blocks saving and says why")
    func validation() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.editor(store)
        model.selectedCode = ReliefCode("LIFESTYLE")

        model.amountText = ""
        #expect(!model.canSave)
        model.amountText = "abc"
        #expect(!model.canSave)
        #expect(model.validationError != nil)
        model.amountText = "0"
        #expect(!model.canSave)
        model.amountText = "-5"
        // A typo'd minus must not quietly reduce someone's relief. See the plan note on
        // net SSPN deposits for the case this deliberately cannot express.
        #expect(!model.canSave)

        model.amountText = "12.34"
        #expect(model.canSave)
        #expect(model.validationError == nil)
    }

    @Test("saving with no relief chosen is blocked")
    func codeIsRequired() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.editor(store)
        model.amountText = "100"
        model.selectedCode = nil
        #expect(!model.canSave)
    }

    @Test("a relief that excludes the taxpayer forces a claimant choice")
    func claimantIsRequiredWhereTheRuleExcludesSelf() async throws {
        let store = try await PresentationFixture.store()
        var mother = DependentDraft(id: UUID(), name: "Mother")
        mother.kind = .parent
        _ = try await store.save(mother)

        let model = await Self.editor(store)
        model.selectedCode = ReliefCode("PARENTS_MEDICAL")
        model.amountText = "1200"

        // PARENTS_MEDICAL admits only .parent and .grandparent. Saved with the default
        // .individual it is refused by the engine and the user loses the claim with no
        // explanation, so the editor refuses first and says why.
        #expect(model.admittedClaimants == [.parent, .grandparent])
        #expect(model.claimant == .individual)
        #expect(!model.canSave)
        #expect(model.validationError != nil)

        model.claimant = .parent
        #expect(model.canSave)
    }

    @Test("a relief that admits the taxpayer saves without touching the claimant")
    func claimantDefaultsWhereTheRuleAdmitsSelf() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.editor(store)
        model.selectedCode = ReliefCode("LIFESTYLE")
        model.amountText = "320"
        // LIFESTYLE admits self, spouse and child. The default is already valid, so the
        // picker must not become a speed bump on the commonest entry in the app.
        #expect(model.admittedClaimants.contains(.individual))
        #expect(model.canSave)
    }

    @Test("a dependent may be named but is never required")
    func dependentIsOptionalAnnotation() async throws {
        let store = try await PresentationFixture.store()
        var farah = DependentDraft(id: UUID(), name: "Farah")
        farah.dateOfBirth = Date(timeIntervalSince1970: 1_253_491_200)
        _ = try await store.save(farah)

        let model = await Self.editor(store)
        model.selectedCode = ReliefCode("LIFESTYLE")
        model.amountText = "320"
        model.claimant = .child

        // Every per-dependent relief is automatic and therefore not offerable, so no
        // entry the user can create needs a dependent for the engine's sake. Naming one
        // is for their own record.
        #expect(model.allowsDependent)
        #expect(model.canSave, "no dependent named, and that is fine")
        #expect(model.availableDependents.contains { $0.id == farah.id })

        model.dependentID = farah.id
        #expect(await model.save())
        let saved = try await store.entryDrafts(forYear: 2025).first { $0.dependentID == farah.id }
        #expect(saved?.claimant == .child)
    }

    @Test("no offerable relief has a per-dependent cap")
    func noOfferableReliefIsPerDependent() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.editor(store)
        let ruleSet = try BundledRuleSetLoader().ruleSet(for: 2025)
        // Pins the fact this design rests on. If a future Budget ships a manually-logged
        // per-dependent relief, this fails and the dependent field must become required
        // for it.
        for option in model.availableCodes {
            if case .perDependent = ruleSet.relief(for: option.code)?.cap {
                Issue.record("\(option.code) is offerable and per-dependent")
            }
        }
    }

    @Test("a same-session duplicate warns but does not block")
    func duplicateWarning() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let existing = try #require(try await store.entryDrafts(forYear: 2025)
            .first { $0.code == ReliefCode("LIFESTYLE") })

        let model = await Self.editor(store)
        model.selectedCode = existing.code
        model.amountText = existing.amount.formattedForEditing()
        model.vendor = existing.vendor
        model.spentOn = existing.spentOn
        await model.checkForDuplicate()

        #expect(model.duplicateWarning != nil)
        // Warns, never blocks: two identical receipts from the same shop on the same day
        // are unusual but real, and refusing the second would make the app wrong about
        // the user's own money.
        #expect(model.canSave)

        model.amountText = "12345"
        await model.checkForDuplicate()
        #expect(model.duplicateWarning == nil)
    }

    @Test("editing an entry does not flag itself as its own duplicate")
    func editingIsNotItsOwnDuplicate() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let existing = try #require(try await store.entryDrafts(forYear: 2025).first)

        let model = await Self.editor(store, editing: existing.id)
        await model.checkForDuplicate()
        #expect(model.duplicateWarning == nil)
    }

    @Test("deleting is undoable")
    func deleteAndUndo() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let existing = try #require(try await store.entryDrafts(forYear: 2025).first)
        let model = await Self.editor(store, editing: existing.id)

        await model.delete()
        #expect(try await store.entryDrafts(forYear: 2025).first { $0.id == existing.id } == nil)

        // Spec §11.6: every destructive action is undoable, on all platforms.
        await model.undoDelete()
        #expect(try await store.entryDrafts(forYear: 2025).first { $0.id == existing.id } != nil)
    }

    @Test("saving refreshes the shared evaluation")
    func saveRefreshesTheContext() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store)
        await context.load()
        let before = try #require(context.result?.assessment(for: ReliefCode("SSPN"))?.claimed)

        let model = EntryEditorViewModel(context: context, store: store, editing: nil)
        await model.load()
        model.selectedCode = ReliefCode("SSPN")
        model.amountText = "750"
        #expect(await model.save())

        // Otherwise Home keeps showing the old headline until something else reloads it,
        // and the user sees their entry vanish into nothing.
        let after = try #require(context.result?.assessment(for: ReliefCode("SSPN"))?.claimed)
        #expect(after == before + Money(ringgit: 750))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "EntryEditor|MoneyParsing"`
Expected: FAIL — "cannot find 'MoneyParsing' in scope".

- [ ] **Step 3: Write the parser**

Create `Sources/TaxPresentation/MoneyParsing.swift`:

```swift
import Foundation
import TaxKit

/// Turns what a user typed into `Money`, without `Double`.
///
/// `Double(text)` would introduce exactly the representation error `Money` exists to
/// prevent, at the one point where the user's own figure enters the system. `Decimal`
/// parses the digits exactly and `Money(ringgit:)` rounds half-up at the sen boundary.
public enum MoneyParsing {

    public static func money(from text: String) -> Money? {
        let cleaned = text
            .replacingOccurrences(of: "RM", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty,
              cleaned.filter({ $0 == "." }).count <= 1,
              cleaned.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }),
              let decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }

        return Money(ringgit: decimal)
    }
}
```

- [ ] **Step 4: Write the editor view model**

Create `Sources/TaxPresentation/EntryEditorViewModel.swift`:

```swift
import Foundation
import Observation
import TaxKit
import TaxData

public struct ReliefOption: Hashable, Sendable, Identifiable {
    public var code: ReliefCode
    public var name: String
    /// Claimants the rulebook admits for this relief. Empty means it places no
    /// restriction, so the taxpayer's own claim is fine.
    public var admittedClaimants: [Claimant]
    public var id: ReliefCode { code }
}

public struct DependentOption: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
}

@MainActor
@Observable
public final class EntryEditorViewModel {

    public var selectedCode: ReliefCode?
    public var amountText: String = ""
    public var vendor: String = ""
    public var spentOn: Date?
    public var claimant: Claimant = .individual
    public var dependentID: UUID?
    public var note: String = ""

    public private(set) var availableCodes: [ReliefOption] = []
    public private(set) var availableDependents: [DependentOption] = []
    public private(set) var isReadOnly = false
    public private(set) var readOnlyReason: String?

    private let context: YearContext
    private let store: TaxStore
    private let editingID: UUID?
    private var deletedID: UUID?

    public init(context: YearContext, store: TaxStore, editing id: UUID?) {
        self.context = context
        self.store = store
        self.editingID = id
    }

    public func load() async {
        availableDependents = ((try? await store.dependentDrafts()) ?? [])
            .map { DependentOption(id: $0.id, name: $0.name) }

        if let result = context.result {
            // Automatic reliefs are excluded. The evaluator grants them in full from
            // household facts and discards any logged amount without a trace, so an
            // entry against one is a figure that silently goes nowhere.
            availableCodes = result.allAssessments
                .filter { !Self.isAutomatic($0.code, in: context) }
                .map { assessment in
                    ReliefOption(code: assessment.code,
                                 name: assessment.name,
                                 admittedClaimants: Self.admittedClaimants(
                                     context.rule(for: assessment.code)))
                }
                .sorted { $0.name < $1.name }
        }

        guard let editingID,
              let existing = try? await store.entryDrafts(forYear: context.year)
                  .first(where: { $0.id == editingID }) else { return }

        selectedCode = existing.code
        amountText = existing.amount.formattedForEditing()
        vendor = existing.vendor
        spentOn = existing.spentOn
        claimant = existing.claimant
        dependentID = existing.dependentID
        note = existing.note

        if Self.isAutomatic(existing.code, in: context) {
            isReadOnly = true
            readOnlyReason = "\(existing.code.rawValue) is granted automatically from your household details. Any amount recorded here is ignored — edit your details instead."
        }
    }

    /// Claimants the selected relief admits. Empty means no restriction.
    public var admittedClaimants: [Claimant] {
        guard let selectedCode else { return [] }
        return availableCodes.first { $0.code == selectedCode }?.admittedClaimants ?? []
    }

    /// Whether naming a dependent is meaningful for this relief. Never required — no
    /// offerable relief has a per-dependent cap, so the engine ignores `dependentID`.
    public var allowsDependent: Bool {
        !admittedClaimants.isEmpty
            && !Set(admittedClaimants).isDisjoint(with: [.child, .parent, .grandparent])
    }

    public var validationError: String? {
        if selectedCode == nil { return "Choose a relief." }
        guard let amount = MoneyParsing.money(from: amountText) else {
            return amountText.isEmpty ? "Enter an amount." : "That is not an amount."
        }
        if amount <= .zero { return "The amount must be more than RM 0.00." }
        let admitted = admittedClaimants
        if !admitted.isEmpty && !admitted.contains(claimant) {
            // PARENTS_MEDICAL admits only .parent and .grandparent. Left at the default
            // .individual it is refused by the engine, and the user loses the claim with
            // no explanation. Refusing here, with a reason, is the whole point.
            return "Choose who this claim is for."
        }
        return nil
    }

    public var canSave: Bool {
        !isReadOnly && validationError == nil
    }

    /// Spec §6.5: same-session duplicates are caught by a prompt at entry time, before
    /// the reconciliation sweep ever has to deal with them.
    ///
    /// Warns rather than blocks. Two identical receipts from the same shop on the same
    /// day are unusual but real, and refusing the second would make the app wrong about
    /// the user's own money. The sweep only ever merges rows that arrived from different
    /// devices; a duplicate the user confirms here is theirs to keep.
    public private(set) var duplicateWarning: String?

    public func checkForDuplicate() async {
        duplicateWarning = nil
        guard let code = selectedCode,
              let amount = MoneyParsing.money(from: amountText) else { return }

        let candidate = DedupeKey.entry(code: code,
                                        amountSen: amount.sen,
                                        day: Normalisation.day(spentOn),
                                        vendor: Normalisation.vendor(vendor))
        let existing = (try? await store.entryDrafts(forYear: context.year)) ?? []
        for entry in existing where entry.id != editingID {
            guard let key = try? await store.dedupeKey(forEntry: entry.id), key == candidate else { continue }
            duplicateWarning = "You already logged \(amount.formatted()) for this. Save anyway?"
            return
        }
    }

    @discardableResult
    public func save() async -> Bool {
        guard canSave,
              let code = selectedCode,
              let amount = MoneyParsing.money(from: amountText) else { return false }

        let draft = EntryDraft(id: editingID ?? UUID(),
                               year: context.year,
                               code: code,
                               amount: amount,
                               claimant: claimant,
                               dependentID: allowsDependent ? dependentID : nil,
                               vendor: vendor.trimmingCharacters(in: .whitespaces),
                               spentOn: spentOn,
                               note: note)

        do {
            _ = try await store.save(draft)
        } catch {
            return false
        }
        // Without this the Home headline keeps its old value until something else
        // reloads, and the user watches their entry vanish into nothing.
        await context.reload()
        return true
    }

    public func delete() async {
        guard let editingID else { return }
        try? await store.softDeleteEntry(id: editingID)
        deletedID = editingID
        await context.reload()
    }

    public func undoDelete() async {
        guard let deletedID else { return }
        try? await store.restoreEntry(id: deletedID)
        self.deletedID = nil
        await context.reload()
    }

    /// Walks a rule's eligibility predicate for the claimants it admits.
    ///
    /// The rulebook is the authority on who a relief may be claimed for, and the closed
    /// predicate language makes this a total function over the tree rather than a guess.
    static func admittedClaimants(_ rule: ReliefRule?) -> [Claimant] {
        guard let predicate = rule?.eligibility else { return [] }

        func walk(_ node: EligibilityPredicate) -> [Claimant] {
            switch node {
            case .claimant(let admitted): return admitted
            case .all(let children), .any(let children): return children.flatMap(walk)
            case .not(let inner): return walk(inner)
            default: return []
            }
        }
        // Order preserved from the rulebook so the picker is stable between launches.
        var seen: Set<Claimant> = []
        return walk(predicate).filter { seen.insert($0).inserted }
    }

    static func isAutomatic(_ code: ReliefCode, in context: YearContext) -> Bool {
        context.rule(for: code)?.automatic ?? false
    }
}

extension Money {
    /// Plain digits for a text field. `formatted()` is for display — putting `RM 1,820.50`
    /// into an editable field means the user has to delete the prefix to type.
    func formattedForEditing() -> String {
        let sign = sen < 0 ? "-" : ""
        let magnitude = abs(sen)
        return "\(sign)\(magnitude / 100).\(String(format: "%02d", magnitude % 100))"
    }
}
```

`context.rule(for:)` does not exist yet. Add to `YearContext`:

```swift
    /// The rulebook entry behind a code, for the few decisions the evaluation result
    /// does not carry — `automatic` chief among them.
    public func rule(for code: ReliefCode) -> ReliefRule? {
        (try? loader.ruleSet(for: year))?.relief(for: code)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "EntryEditor|MoneyParsing"`
Expected: PASS — 17 tests in 2 suites.

Note that `.claimant(in:)` is the only predicate case consulted here. `Cap` as shipped has exactly three cases — `.fixed(Money)`, `.perDependent(Money)` and
`.tiered(on:tiers:)`. There is no `sharedPool` or `none`; a shared pool is modelled as a
parent relief with children, and an uncapped relief does not exist in any shipped year.

- [ ] **Step 6: Commit**

```bash
git add Sources/TaxPresentation Tests/TaxPresentationTests
git commit -m "feat: add the entry editor view model, refusing entries against automatic reliefs"
```

---

### Task 16: The entry editor screen, the undo toast and the year switcher

**Files:**
- Create: `App/TaxTracker/Entries/EntryEditorView.swift`
- Create: `App/TaxTracker/Support/UndoToast.swift`
- Modify: `App/TaxTracker/RootView.swift` (year menu, add button, editor presentation)

**Interfaces:**
- Consumes: `EntryEditorViewModel` from Task 15, `YearContext` from Task 10.
- Produces: `EntryEditorView`, `UndoToast`, the year-switching title menu.

**The year switcher lives in the navigation title**, per spec §11 — "Compare lives in the
year-title menu". Building it as a `Menu` on the title now means the Compare screen has
its home already made.

**The undo toast owns a deadline, not a `Task.sleep` chain.** A toast that dismisses via a
detached sleep keeps firing after the view is gone and can restore an entry the user has
since re-created. It holds the deleted id and a dismissal date; the view drives it.

- [ ] **Step 1: Write the undo toast**

Create `App/TaxTracker/Support/UndoToast.swift`:

```swift
import SwiftUI

/// A transient "Deleted · Undo" bar.
///
/// Spec §11.6: every destructive action is undoable, on every platform. The undo action
/// is passed in rather than owned here, because what to undo is the view model's
/// business and a toast that knows about entries would need rewriting for documents.
struct UndoToast: View {
    let message: String
    let undo: () async -> Void
    @Binding var isPresented: Bool

    var body: some View {
        HStack {
            Text(message)
            Spacer()
            Button("Undo") {
                Task {
                    await undo()
                    isPresented = false
                }
            }
            .fontWeight(.semibold)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thickMaterial, in: Capsule())
        .padding(.horizontal, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task {
            // Bound to the view's lifetime: when the toast goes away, so does the timer.
            // A detached sleep would keep firing and could restore an entry the user has
            // since re-created.
            try? await Task.sleep(for: .seconds(5))
            isPresented = false
        }
    }
}
```

- [ ] **Step 2: Write the editor screen**

Create `App/TaxTracker/Entries/EntryEditorView.swift`:

```swift
import SwiftUI
import TaxKit
import TaxPresentation

struct EntryEditorView: View {

    @Bindable var model: EntryEditorViewModel
    @Environment(\.dismiss) private var dismiss
    let onDeleted: (EntryEditorViewModel) -> Void

    @State private var hasDate = false

    var body: some View {
        NavigationStack {
            Form {
                if let reason = model.readOnlyReason {
                    Section {
                        Label(reason, systemImage: "info.circle")
                            .font(.footnote)
                    }
                }

                Section {
                    Picker("Relief", selection: $model.selectedCode) {
                        Text("Choose…").tag(ReliefCode?.none)
                        ForEach(model.availableCodes) { option in
                            Text(option.name).tag(ReliefCode?.some(option.code))
                        }
                    }

                    LabeledContent("Amount") {
                        TextField("0.00", text: $model.amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }

                    if !model.admittedClaimants.isEmpty {
                        Picker("Claimed for", selection: $model.claimant) {
                            ForEach(model.admittedClaimants, id: \.self) { who in
                                Text(who.rawValue.capitalized).tag(who)
                            }
                        }
                    }

                    if model.allowsDependent, !model.availableDependents.isEmpty {
                        Picker("Which person", selection: $model.dependentID) {
                            Text("Not specified").tag(UUID?.none)
                            ForEach(model.availableDependents) { dependent in
                                Text(dependent.name).tag(UUID?.some(dependent.id))
                            }
                        }
                    }
                }

                Section {
                    TextField("Vendor", text: $model.vendor)
                    Toggle("Has a date", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Spent on",
                                   selection: Binding(get: { model.spentOn ?? Date() },
                                                      set: { model.spentOn = $0 }),
                                   displayedComponents: .date)
                    }
                    TextField("Note", text: $model.note, axis: .vertical)
                }

                if let error = model.validationError, !model.amountText.isEmpty {
                    Section { Text(error).foregroundStyle(.orange).font(.footnote) }
                } else if let warning = model.duplicateWarning {
                    Section {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }

                if model.readOnlyReason == nil, model.canDelete {
                    Section {
                        Button("Delete", role: .destructive) {
                            Task {
                                await model.delete()
                                onDeleted(model)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle(model.isEditing ? "Edit entry" : "New entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { if await model.save() { dismiss() } }
                    }
                    .disabled(!model.canSave)
                }
            }
            .task {
                await model.load()
                hasDate = model.spentOn != nil
            }
            .onChange(of: hasDate) { _, isOn in
                if !isOn { model.spentOn = nil }
            }
            // Spec §6.5: catch the duplicate at entry time, before the sweep has to.
            .onChange(of: model.amountText) { Task { await model.checkForDuplicate() } }
            .onChange(of: model.vendor) { Task { await model.checkForDuplicate() } }
            .onChange(of: model.selectedCode) { Task { await model.checkForDuplicate() } }
        }
    }
}
```

Add the two properties the view needs to `EntryEditorViewModel`:

```swift
    public var isEditing: Bool { editingID != nil }
    public var canDelete: Bool { editingID != nil && !isReadOnly }
```

- [ ] **Step 3: Wire the year menu, the add button and the editor into the shell**

In `RootView`, add state:

```swift
    @State private var editingEntry: EntryEditorViewModel?
    @State private var showUndo = false
    @State private var lastDeleted: EntryEditorViewModel?
```

Replace the Home tab's `NavigationStack` contents' `.navigationTitle` with a title menu,
and add the button and sheet:

```swift
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Menu {
                                ForEach(context.availableYears.reversed(), id: \.self) { year in
                                    Button {
                                        Task {
                                            await context.switchYear(to: year)
                                            await home.refresh()
                                        }
                                    } label: {
                                        // The check marks the current year; Compare joins
                                        // this menu in a later plan, which is why the
                                        // switcher lives in the title rather than a tab.
                                        Label("YA \(String(year))",
                                              systemImage: year == context.year ? "checkmark" : "")
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("YA \(String(context.year))").fontWeight(.semibold)
                                    Image(systemName: "chevron.down").font(.caption2)
                                }
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                editingEntry = EntryEditorViewModel(context: context,
                                                                    store: store,
                                                                    editing: nil)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel("Add an entry")
                        }
                    }
                    .navigationDestination(for: EntryRoute.self) { route in
                        EntryEditorView(
                            model: EntryEditorViewModel(context: context, store: store,
                                                        editing: route.entryID),
                            onDeleted: handleDeleted)
                    }
```

and attach the sheet and the toast to the `TabView`:

```swift
        .sheet(item: $editingEntry) { model in
            EntryEditorView(model: model, onDeleted: handleDeleted)
        }
        .overlay(alignment: .bottom) {
            if showUndo, let lastDeleted {
                UndoToast(message: "Entry deleted",
                          undo: {
                              await lastDeleted.undoDelete()
                              await home.refresh()
                          },
                          isPresented: $showUndo)
                .padding(.bottom, 60)
            }
        }
        .animation(.spring(duration: 0.3), value: showUndo)
```

with the handler:

```swift
    private func handleDeleted(_ model: EntryEditorViewModel) {
        lastDeleted = model
        showUndo = true
        Task { await home.refresh() }
    }
```

`EntryEditorViewModel` must be `Identifiable` for `.sheet(item:)`. Add to Task 15's class:

```swift
extension EntryEditorViewModel: Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
```

- [ ] **Step 4: Build, then drive the flow in the simulator**

Run: `./Scripts/build-app.sh`
Expected: "Build succeeded."

Launch, then verify by hand — this is the flow `swift test` cannot see:

1. Tap **+**, choose a relief, enter `320.50`, save. The Home headline changes.
2. Confirm `SELF_AND_DEPENDENTS` (and the other automatic reliefs) are absent from the
   relief picker.
2a. Tap **+** again and re-enter the same relief, amount and vendor. The duplicate warning
   appears and **Save** stays enabled.
3. Tap **See all**, open the relief, open the entry, delete it. The undo toast appears.
4. Tap **Undo**. The entry comes back and the headline returns to its previous value.
5. Open the year menu, switch to YA2024, and confirm the screen re-evaluates.

Capture a screenshot of the editor and of Home with an entry logged.

- [ ] **Step 5: Run the whole suite and commit**

Run: `swift test`
Expected: PASS, no regressions.

```bash
git add App Sources/TaxPresentation
git commit -m "feat: add the entry editor, the undo toast and the year switcher"
```

---

### Task 17: Onboarding and the household facts

**Files:**
- Create: `Sources/TaxPresentation/OnboardingViewModel.swift`
- Create: `App/TaxTracker/Onboarding/OnboardingView.swift`
- Modify: `App/TaxTracker/RootView.swift` (first-launch gate)
- Test: `Tests/TaxPresentationTests/OnboardingViewModelTests.swift`

**Interfaces:**
- Consumes: `TaxStore.saveYearFacts(_:for:)`, `savePreferences(_:)`, `preferences()`.
- Produces:
  - `@MainActor @Observable public final class OnboardingViewModel` — `step`, `facts`,
    `incomeEnabled`, `advance()`, `skip()`, `finish()`.
  - `enum OnboardingStep: Int, CaseIterable { case welcome, household, income }`

**Three screens, all skippable, income last and optional.** Spec §1's first success
criterion is logging a receipt within 30 seconds of first launch, without an account and
without entering income. Onboarding that demands a salary before showing anything fails
that outright. Skipping leaves every fact `nil`, which the engine renders as prompts on
Home — the user is asked later, in context, by a screen that can say what the answer is
worth.

**Onboarding writes household facts to the *current* year only.** Marital status and
income change between years, and copying them forward would assert facts about YA2023
that the user never gave. A later year switch finds empty facts and prompts.

- [ ] **Step 1: Write the failing test**

Create `Tests/TaxPresentationTests/OnboardingViewModelTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

@Suite("OnboardingViewModel") @MainActor struct OnboardingViewModelTests {

    @Test("finishing writes the facts and marks onboarding done")
    func finishPersists() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)

        model.facts.maritalStatus = .married
        model.facts.spouseHasIncome = false
        model.incomeEnabled = true
        model.facts.grossIncome = Money(ringgit: 128_000)
        await model.finish()

        let facts = try await store.yearFacts(for: 2025)
        #expect(facts.maritalStatus == .married)
        #expect(facts.grossIncome == Money(ringgit: 128_000))

        let preferences = try await store.preferences()
        #expect(preferences.hasCompletedOnboarding)
        #expect(preferences.incomeModuleEnabled)
    }

    @Test("skipping leaves every fact unanswered")
    func skipLeavesFactsNil() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        await model.skip()

        let facts = try await store.yearFacts(for: 2025)
        // nil, not a default. Spec §1: a receipt must be loggable in 30 seconds without
        // entering income, and a guessed marital status would silently change what the
        // engine grants.
        #expect(facts.maritalStatus == nil)
        #expect(facts.grossIncome == nil)
        #expect(try await store.preferences().hasCompletedOnboarding)
        #expect(try await store.preferences().incomeModuleEnabled == false)
    }

    @Test("income left off is not written even if a figure was typed")
    func incomeToggleGates() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.facts.grossIncome = Money(ringgit: 128_000)
        model.incomeEnabled = false
        await model.finish()

        // Otherwise turning the module off in Settings would leave a stale salary driving
        // every tax figure in the app.
        #expect(try await store.yearFacts(for: 2025).grossIncome == nil)
    }

    @Test("facts are written to the chosen year only")
    func factsAreScopedToTheYear() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.facts.maritalStatus = .married
        await model.finish()

        // Copying forward would assert facts about YA2023 the user never gave.
        #expect(try await store.yearFacts(for: 2023).maritalStatus == nil)
        #expect(try await store.yearFacts(for: 2025).maritalStatus == .married)
    }

    @Test("steps advance in order and stop at the end")
    func stepping() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        #expect(model.step == .welcome)
        model.advance()
        #expect(model.step == .household)
        model.advance()
        #expect(model.step == .income)
        #expect(model.isLastStep)
        model.advance()
        #expect(model.step == .income)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter Onboarding`
Expected: FAIL — "cannot find 'OnboardingViewModel' in scope".

- [ ] **Step 3: Write the view model**

Create `Sources/TaxPresentation/OnboardingViewModel.swift`:

```swift
import Foundation
import Observation
import TaxKit
import TaxData

public enum OnboardingStep: Int, CaseIterable, Hashable, Sendable {
    case welcome, household, income
}

/// Three skippable screens. Spec §11.
///
/// Nothing here is required. Skipping leaves every fact `nil`, which the engine renders
/// as prompts on Home — the user gets asked later, in context, by a screen that can say
/// what the answer is worth. That is strictly better than a wall of questions before the
/// app has shown it is useful.
@MainActor
@Observable
public final class OnboardingViewModel {

    public private(set) var step: OnboardingStep = .welcome
    public var facts = YearFacts()
    public var incomeEnabled = false

    private let store: TaxStore
    private let year: Int

    public init(store: TaxStore, year: Int) {
        self.store = store
        self.year = year
    }

    public var isLastStep: Bool { step == OnboardingStep.allCases.last }

    public func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    public func skip() async {
        facts = YearFacts()
        incomeEnabled = false
        await complete()
    }

    public func finish() async {
        await complete()
    }

    private func complete() async {
        var toSave = facts
        if !incomeEnabled {
            // Otherwise turning the module off later leaves a stale salary quietly
            // driving every tax figure in the app.
            toSave.grossIncome = nil
            toSave.epf = nil
            toSave.socso = nil
        }

        try? await store.saveYearFacts(toSave, for: year)

        if var preferences = try? await store.preferences() {
            preferences.hasCompletedOnboarding = true
            preferences.incomeModuleEnabled = incomeEnabled
            preferences.lastViewedYear = year
            try? await store.savePreferences(preferences)
        }
    }
}
```

- [ ] **Step 4: Write the onboarding screens**

Create `App/TaxTracker/Onboarding/OnboardingView.swift`:

```swift
import SwiftUI
import TaxKit
import TaxPresentation

struct OnboardingView: View {

    @Bindable var model: OnboardingViewModel
    let onFinished: () -> Void

    @State private var incomeText = ""

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)

            VStack(spacing: 12) {
                Button(model.isLastStep ? "Done" : "Continue") {
                    if model.isLastStep {
                        model.facts.grossIncome = MoneyParsing.money(from: incomeText)
                        Task { await model.finish(); onFinished() }
                    } else {
                        model.advance()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Skip for now") {
                    Task { await model.skip(); onFinished() }
                }
                .font(.subheadline)
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            VStack(spacing: 12) {
                Text("Relio").font(.largeTitle.bold())
                Text("Track your Malaysian tax relief. No account, no server — your data stays on your devices.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("Estimates only. Verify with LHDN before you file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }

        case .household:
            Form {
                Section("Your household") {
                    Picker("Marital status", selection: $model.facts.maritalStatus) {
                        Text("Prefer not to say").tag(MaritalStatus?.none)
                        ForEach(MaritalStatus.allCases, id: \.self) { status in
                            Text(status.rawValue.capitalized).tag(MaritalStatus?.some(status))
                        }
                    }
                    if model.facts.maritalStatus == .married {
                        Toggle("My spouse has income",
                               isOn: Binding(get: { model.facts.spouseHasIncome ?? false },
                                             set: { model.facts.spouseHasIncome = $0 }))
                    }
                } footer: {
                    Text("You can leave these blank. Relio will ask again when an answer would unlock a relief.")
                }
            }
            .scrollContentBackground(.hidden)

        case .income:
            Form {
                Section {
                    Toggle("Show what relief saves me", isOn: $model.incomeEnabled)
                    if model.incomeEnabled {
                        LabeledContent("Annual income") {
                            TextField("0.00", text: $incomeText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Text("Optional. Without it Relio still tracks every relief and cap — it just cannot tell you what they are worth in tax.")
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}
```

- [ ] **Step 5: Gate first launch in `RootView`**

Add state and a check:

```swift
    @State private var needsOnboarding: Bool?

    // inside .task, before loading:
            needsOnboarding = !((try? await store.preferences().hasCompletedOnboarding) ?? false)
```

and wrap the `TabView`:

```swift
        Group {
            if needsOnboarding == true {
                OnboardingView(model: OnboardingViewModel(store: store, year: context.year)) {
                    needsOnboarding = false
                    Task { await context.reload(); await home.refresh() }
                }
            } else if needsOnboarding == false {
                tabs
            } else {
                ProgressView()
            }
        }
```

moving the existing `TabView` into a `private var tabs: some View`. The tri-state
matters: `nil` means the preference has not been read yet, and defaulting it to "show
onboarding" would flash the welcome screen at every returning user on every launch.

- [ ] **Step 6: Run the tests, build, and verify first launch**

Run: `swift test --filter Onboarding`
Expected: PASS — 5 tests.

Run: `./Scripts/build-app.sh`

Then verify on a clean install:

```bash
xcrun simctl uninstall "Relio Test Phone" my.relio.TaxTracker
```

Reinstall and launch. Expected: onboarding appears, "Skip for now" reaches Home, and a
second launch goes straight to Home.

- [ ] **Step 7: Commit**

```bash
git add Sources/TaxPresentation Tests/TaxPresentationTests App
git commit -m "feat: add skippable onboarding writing household facts to the current year"
```

---

### Task 18: Accessibility, Dynamic Type, and the end-to-end pass

**Files:**
- Modify: any view whose audit fails
- Create: `Tests/TaxPresentationTests/FormattingDisciplineTests.swift`
- Modify: `README.md` (current-state table)

**Interfaces:**
- Consumes: everything.
- Produces: no new API. This task is the gate on Phase B.

**The formatter rule becomes a test.** A global constraint says interpolating an amount
into user-facing text is a defect, and `MoneyText` exists so that is greppable. A grep is
only run by whoever remembers to run it, so the audit becomes an assertion over the
presentation layer's own strings.

- [ ] **Step 1: Write the formatting-discipline test**

Create `Tests/TaxPresentationTests/FormattingDisciplineTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
@testable import TaxPresentation

@Suite("Formatting discipline") struct FormattingDisciplineTests {

    @Test("the formatter produces the one shape the whole app uses")
    func formatterShape() {
        #expect(Money(ringgit: 2_500).formatted() == "RM 2,500.00")
        #expect(Money.zero.formatted() == "RM 0.00")
        #expect(Money(sen: 5).formatted() == "RM 0.05")
    }

    @Test("editing format is plain digits, not display format")
    func editingFormat() {
        // A text field prefilled with "RM 1,820.50" makes the user delete the prefix
        // before they can type. Display and editing are different jobs.
        #expect(Money(sen: 182_050).formattedForEditing() == "1820.50")
        #expect(Money(sen: 5).formattedForEditing() == "0.05")
    }

    @Test("what the parser writes, the editing formatter reads back")
    func parseFormatRoundTrip() {
        for sen in [0, 1, 99, 100, 182_050, 12_800_000] {
            let money = Money(sen: sen)
            #expect(MoneyParsing.money(from: money.formattedForEditing()) == money)
        }
    }

    @Test("no presentation type builds an amount string by interpolation")
    func noInterpolatedAmounts() throws {
        // Walks the source rather than the runtime: the defect this guards against is a
        // future edit writing "RM \(money.sen / 100)" somewhere, which no behavioural
        // test would catch because it looks right for round numbers.
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()     // Tests/TaxPresentationTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // package root
            .appending(path: "Sources/TaxPresentation")

        let files = try FileManager.default
            .contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                // Flags a display string built by hand: the prefix immediately followed
                // by an interpolation, or the prefix with its trailing space. A bare
                // "RM" with no space is stripping, not building — MoneyParsing does
                // exactly that — so `replacingOccurrences` lines are skipped.
                guard text.contains("RM \\(") || text.contains("\"RM ") else { continue }
                guard !text.contains("replacingOccurrences") else { continue }
                #expect(text.contains("//"),
                        "\(file.lastPathComponent):\(number + 1) builds an RM string by hand — use Money.formatted()")
            }
        }
    }
}
```

- [ ] **Step 2: Run it and fix what it finds**

Run: `swift test --filter FormattingDiscipline`
Expected: PASS — 4 tests. If the last one fails, replace the hand-built string with
`Money.formatted()`; do not weaken the test.

- [ ] **Step 3: Audit Dynamic Type and VoiceOver in the simulator**

Launch the app with an entry logged, then check each item and fix what fails:

- [ ] **Dynamic Type at AX5.** Settings → Accessibility → Display & Text Size → Larger
      Text, dragged to maximum. Every screen must remain usable: no clipped labels, no
      truncated amounts, no button pushed off-screen. Fix by letting rows wrap
      (`.lineLimit(nil)`, `ViewThatFits`, or moving the trailing figure below the label),
      never by pinning a font size — spec §11.2 forbids fixed point sizes.
- [ ] **VoiceOver on Home and the reliefs list.** Each opportunity row must read as
      "Lifestyle, RM 800.00 still claimable, worth RM 152.00 in tax", never "68 percent".
      Spec §11.8.
- [ ] **Reduce Motion.** Settings → Accessibility → Motion → Reduce Motion on. The
      headline's `.contentTransition(.numericText())` and the toast's spring must not
      animate. SwiftUI honours this for the standard transitions used here; confirm it
      rather than assuming.
- [ ] **Dark Mode.** Every screen. The design uses semantic colours only — one accent,
      everything else system — so a failure here means a hardcoded colour crept in.
- [ ] **The estimate disclaimer is reachable.** Spec §13 lists "user treats estimates as
      tax advice" as a named risk, mitigated by a disclaimer on computed figures and
      per-relief LHDN links. Confirm the relief detail screen shows both.

Capture screenshots at default and at AX5 for the record.

- [ ] **Step 4: Run the full gate**

```bash
swift test
./Scripts/build-app.sh
grep -rn "import SwiftData\|import SwiftUI" Sources/TaxKit --include=*.swift
grep -rn "import SwiftUI" Sources/TaxData Sources/TaxPresentation --include=*.swift
```

Expected: tests pass; the build succeeds; both greps return nothing. The second grep is
the one that matters for Task 13 onward — a view model that imports SwiftUI has stopped
being testable by `swift test` and the discipline has quietly ended.

- [ ] **Step 5: Update the README's current-state table**

Replace the table in `README.md` with:

```markdown
| | Status |
|---|---|
| **TaxKit** — the tax engine behind Relio | ✅ Done |
| **TaxData** — SwiftData models, TaxStore, dedupe, reconciliation | ✅ Done |
| **TaxPresentation** — tested view models | ✅ Done |
| iOS app — Home, Reliefs, entry CRUD, onboarding | ✅ Done |
| iCloud sync | Built, not verified end to end — needs two signed-in devices |
| Receipt capture, OCR, MyInvois e-invoices | Not started |
| On-device AI assistant | Not started |
| watchOS, macOS, widgets | Not started |
```

and add a build section:

```markdown
## Running the app

```bash
cp Config/Signing.example.xcconfig Config/Signing.xcconfig   # first time only
./Scripts/build-app.sh
```

The app builds and runs with no Apple Developer account, storing data locally. To enable
iCloud sync, put your team id in `Config/Signing.xcconfig` and point
`TAXTRACKER_ENTITLEMENTS` at `App/TaxTracker/TaxTracker.entitlements`.
```

- [ ] **Step 6: Commit**

```bash
git add Tests/TaxPresentationTests README.md App Sources
git commit -m "test: enforce the money-formatting discipline and complete the accessibility pass"
```

---

## Definition of done

Plan 2 is complete when all of the following hold:

- [ ] `swift build` succeeds with no warnings under Swift 6 language mode.
- [ ] `swift test` passes every suite across `TaxKitTests`, `TaxDataTests` and
      `TaxPresentationTests`, with Plan 1's 136 tests unchanged and still passing.
- [ ] `./Scripts/build-app.sh` succeeds from a clean checkout after copying the signing
      template, with no Apple Developer account.
- [ ] The app launches on the simulator, completes onboarding, logs an entry, shows a
      changed headline, deletes it, and undoes the delete.
- [ ] `grep -rn "import SwiftData\|import SwiftUI" Sources/TaxKit` returns nothing.
- [ ] `grep -rn "import SwiftUI" Sources/TaxData Sources/TaxPresentation` returns nothing.
- [ ] `grep -rn "Double" Sources/TaxData Sources/TaxPresentation --include=*.swift`
      returns nothing outside the `ProgressView` render boundary in the app target.
- [ ] `SchemaInvariantTests` passes over `SchemaV1.models`, and the harness's
      non-vacuity test passes.
- [ ] `PersistedGoldenTests` reproduces `golden-ya2025.json` exactly from data seeded
      through `TaxStore`.
- [ ] No view or view model references `ModelContext`:
      `grep -rn "ModelContext" Sources/TaxPresentation App` returns nothing.
- [ ] The reconciliation sweep's order-independence test has been observed failing with
      the tie-break removed, and the `not`-over-dependent-facts guard has been observed
      failing with a `not` injected into a rulebook.

**What this plan does not prove.** End-to-end CloudKit sync. The models are verified
mirroring-safe structurally, the container is configured for the private database, and
the reconciliation sweep is proven deterministic and idempotent — but no test here has
two devices, an iCloud account, or a paid team. The first real sync will surface things
this suite cannot: schema rejections at the CloudKit boundary, first-sync ordering, and
the offline-then-online migration in spec §6's third failure mode. That verification
needs a device pair and belongs in its own plan. Do not report sync as working.

## Carried forward to later plans

Recorded here so a reviewer does not report them as gaps, and so the plan that owns each
one knows to pick it up:

1. **`unmerge` is undone by the next sweep.** Restoring a merged entry makes its group a
   duplicate again, so `reconcile()` re-merges it. Needs a "the user decided these are
   different" marker, which belongs with the merge UI in the Documents plan (Task 6).
2. **A negative net SSPN year cannot be entered.** LHDN defines the relief as net
   deposits and the engine handles a negative correctly, but the editor rejects it and
   there is no "this is a withdrawal" affordance. Belongs with SSPN-specific UI (Task 15).
3. **`availableYears` is hardcoded** in `BundledRuleSetLoader` rather than derived from
   bundle contents, so adding a rulebook means editing two places. Deferred from Plan 1.
4. **A missing bundle resource reports `.noRulesForYear`**, indistinguishable from an
   unshipped year. Only reachable via a build defect. Deferred from Plan 1.
5. **`recomputeAllDedupeKeys()` has no caller.** The dedupe key's shape changed twice
   during this plan's execution, so any row persisted under an earlier shape would keep a
   stale key and be unmatchable against new ones — which silently breaks the sweep.
   Harmless today because nothing has shipped, but the migration hook must be wired to run
   once on launch after a key-format change before first release.
6. **`Document`, `DocumentFile` and `ChatMessage` are models with no producer.** They are
   in schema V1 because the schema must be complete on the first commit; the pipelines
   that fill them are the Documents and Assistant plans.
7. **Documents tab and Ask tab are placeholders.** Spec §15 items 5 and 7.
8. **The Compare screen is not built**, though `counterfactual` and `diff` have shipped
   and are tested since Plan 1. Spec §15 item 6.
