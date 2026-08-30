# SDD ledger — plan: docs/superpowers/plans/2026-08-25-income-timeline.md

Spec: `docs/superpowers/specs/2026-08-25-income-timeline-design.md` (read — binding authority)
Branch: `feat/income-timeline`, forked from `feat/persistence-and-ios-shell`
PLAN-BASE: `da05386`
Merged: `ccedcb2` into `feat/persistence-and-ios-shell`, then `ad92f4b` onto `master`
Executed with superpowers:subagent-driven-development — a fresh implementer per task,
a spec+quality review after each, a fix loop, then one whole-branch review and one fix wave.

Baseline at start: **305 tests**. At merge: **399 tests**, none removed.

---

## Pre-flight conflict scan

Sixteen cross-task pairs sharing a file or interface were checked, plus each task's
internal self-agreement. Every produced/consumed interface matched. Four defects were
found in the plan text itself before any code was written:

| Task | Finding | Resolution |
|---|---|---|
| 1 | `SchemaV1.swift`'s doc comment forbade exactly what Task 1 does ("never edit V1") | Ruling 2 |
| 5 | Step 5's call-site list was incomplete — `ModelTests`, `MigrationTests`, `ReconciliationTests` and the `insertDuplicateYearForTesting` seam also referenced the removed fields | Ruling 3 |
| 6 | `editKeepsItsIdentity` used `produced??.id` on a single optional — will not compile | Ruling 4 |
| 7 | The replacement text silently dropped `complete()`'s existing `!incomeEnabled` clearing | Ruling 5 |

---

## Task record

| Task | Commits | Review outcome | Tests |
|---|---|---|---|
| 1 — the two models and the schema | `c350a72` | clean | 312 |
| 2 — `IncomeCalendar` | `69dab65`, `5b0ada0` | 1 fix round | 321 |
| 3 — `IncomeDerivation` | `9948fa4` | clean | 336 |
| 4 — `TaxStore+Income` | `66fcea9`, `e04d6af` | 1 fix round | 345 |
| 5 — `TaxYear` switch-over | `1abc5b6`, `a99c827` | 1 fix round | 360 |
| 6 — `IncomeViewModel` | `148ea74`, `f64c4e7` | 1 fix round | 374 |
| 7 — Income screen + onboarding | `801a55d`, `9e1308c` | 1 fix round | 381 |
| 8 — verification and docs | `3830aea`, `0a69359` | 1 fix round | 382 |
| final review fix wave | `bdd95c7`, `a349805`, `1837b93`, `50f9303`, `b200a16` | re-review: ready to merge | 399 |

No fix loop exceeded one round; the five-round breaker never tripped.

Task 7's first fix agent died mid-work on an infrastructure API error (403), having
implemented but not verified or committed. A second agent validated the uncommitted draft,
ran the gates and landed it. No work was lost.

---

## Rulings

Decisions taken during execution. Each names what it costs if wrong.

### Process

1. **Worked on a branch off `feat/persistence-and-ios-shell` in the primary checkout, not a
   separate worktree.** Plan 3 builds on Plan 2's then-unmerged commits, and `Scripts/` is
   path-sensitive to this checkout. *Cost: no parallel isolation; recoverable by moving the branch.*

### Against the plan text (the plan specified these; they were overridden)

2. **`SchemaV1` amended in place, and its doc comment corrected.** Spec §9: V1 has not
   shipped, so this is free exactly once. Leaving a comment forbidding what the file now
   does would mislead the next implementer. *Cost: a comment edit.*
3. **Supplied the complete call-site list for Task 5.** *Cost: none — a superset of what the compiler names.*
4. **`produced??.id` → `produced?.id`.** `try? #require(...)` yields a single optional.
   Assertion intent preserved exactly. *Cost: none; the alternative does not compile.*
5. **Kept `complete()`'s `!incomeEnabled` clearing of `grossIncomeOverride`.** *Cost: one redundant nil-assignment.*
6. **The DoD's "roughly 45 tests" is a floor, not an equality.** *Cost: none.*
7. **`monthSpans`' silent-truncation paths trapped with `assertionFailure`, not
   `preconditionFailure`.** A `break` on a failed `Calendar` lookup silently undercounts
   income; spec §5 makes this the path where an off-by-one is "a real ringgit error".
   Crashing a shipped tax app is a worse failure than a degraded span, so it traps in
   debug/test and degrades in release. *Cost: a dev-only trap on input Task 3 already clamps.*
8. **`save(_ draft: IncomeRecordDraft)` throws `IncomeStoreError.unknownIncomeSource` rather
   than silently orphaning a record.** Verified reachable through the plan's own Task 7 code
   (`(try? await store.save(...)) ?? UUID()`), which would have orphaned a user's entire
   onboarding salary with no error. *Cost: one new public error type.*
9. **`IncomeDerivation.knownAnnualGross` replaced the projection's "does any source exist"
   guard.** The original checked the wrong question while its doc comment claimed the right
   one, so a user whose timeline covered 2025 saw a confident **RM 0.00 tax bill** for YA2024.
   Implemented by reusing the existing span walk via a shared `contributions` helper, so
   "does it contribute" and "what does it contribute" cannot drift.
   *Cost: the unknown/zero boundary is "at least one live record intersects the year".*
10. **Income writes report failure.** `addSource` returned `(try? save(draft)) ?? draft.id`,
    and `save` returns `draft.id` on success — so the value was identical whether the write
    succeeded or threw. Now `addSource -> UUID?`, `addRecord -> Bool`, `saveOverride -> Bool`,
    matching `EntryEditorViewModel.save()`'s established shape. *Cost: three signatures gained return values.*
11. **`deleteSource`/`deleteRecord` deliberately left swallowing at Task 6** (later given
    `Bool` in the final wave). A failed delete leaves income counted, which *overstates*
    chargeable income — the conservative direction under spec §8, and the opposite of the
    silent loss the other writes risked. *Cost: a failed delete was silent for one task.*
12. **`IncomeSourceRow.warning` replaced a substring match** (`outOfScopeWarnings.first(where:
    { $0.contains(source.name) })`) joining a compliance notice to its source. "Rental" and
    "Rental Penang" could attach the wrong notice. *Cost: none.*
13. **Out-of-year records: fixed the trigger, not the display.** The editor's default date was
    anchored into the viewed year; non-contributing rows were deliberately **not** labelled,
    because labelling by date is wrong — a recurring rate dated 1 April 2024 with no successor
    legitimately contributes to YA2025. Carried forward as item 6. *Cost: a deliberately chosen
    out-of-year date still shows a row the subtotal excludes.*
14. **Source deletion confirmed; per-record swipe not.** A swipe is already a deliberate
    gesture and the stakes are one row. Undo parity needs a `restore` API in `TaxStore`,
    beyond this plan. Carried forward as item 5. *Cost: record deletion is unrecoverable from the UI.*
15. **The README's income bullet moved off `## What TaxKit does`.** That section opens "A pure
    Swift package with no SwiftData…"; the bullet contradicted the sentence above it and
    attributed a `TaxData` capability to the engine this plan proves untouched. *Cost: a small restructure.*
16. **The no-`Double` gate tests only the pre-comment segment of each line.** `text.contains("//")`
    passed `let x: Double = 0 // temp`. *Cost: none; strictly stricter.*

### A ruling that caused a bug

17. **Ruling 13 anchored new records to 1 January of the viewed year — which tied with the
    rate onboarding writes on exactly that date.** Two rates on one day resolve by
    `id.uuidString`: deterministic across devices, but a coin flip with respect to the user's
    intent. Corrected in the final wave to "the day after the source's latest record, clamped
    into the year". Recorded because the second-order effect was not foreseen when the first
    ruling was made.

### Deviations accepted from implementers

18. **Task 3's test helper split into two overloads** — the plan's `source(...)` signature did
    not compile (Swift cannot skip a defaulted unlabelled parameter before another unlabelled
    one). Verified by diff that no assertion or expected value changed.
19. **Task 7 replaced `.onSubmit` with focus-loss commit** — `.onSubmit` can never fire on a
    `.decimalPad`, which has no return key, so the plan's override field would have discarded
    every typed figure. Added `overrideEditingText` because `Money.formattedForEditing()` is
    module-internal and a view cannot produce it.
20. **Task 7 used `.alert` rather than `confirmationDialog`** — the dialog draws as a popover
    on this OS and clipped at AX5.
21. **The final wave consolidated `refresh()`'s reads into `TaxStore.incomeSummary(for:)`**
    rather than merely deleting one read as instructed. The instructed fix would have left the
    new source-edit path unable to carry `deductsEPF`/`deductsSOCSO`, and a partial draft
    round-tripped through `TaxStore.save` nulls them — violating "unknown stays unknown".
    Re-review judged the deviation better than the instruction.
22. **The final wave added an `internal` `TaxStore.incomeRecordWriteFailure` test seam.** A
    SwiftData write cannot otherwise be made to fail, leaving the onboarding-refuses-to-complete
    branch asserted by nothing. Scoped to the record write to reproduce the realistic partial
    failure (source written, rate not). Not reachable from the app target.

### Parked at the final gate (real, not load-bearing)

23. Onboarding can leave a record-less "Main job" if the user abandons after a failed record
    write — strictly better than the pre-fix behaviour, which left the same orphan *and*
    completed silently. The source contributes nothing, so no figure is wrong.
24. The end-date `DatePicker` has no `in:` range and renders in `.addSource` mode too;
    `sourceSubtotal` gates on the year-level known/unknown flag, so an ended job beside an
    active one still shows RM 0.00 at row level (carried forward, item 6).

---

## What the final whole-branch review caught that eight task reviews could not

Every task was individually compliant with its brief, so no task-scoped review could see it:
**`endedOn` had no UI.** It was plumbed through the model, snapshots, derivation, store and
their tests, but nothing in `App/` or `TaxPresentation` could set it, and there was no
source-edit or rename path at all.

A user changing jobs would add a second source and the old rate would run forever: RM 8,000/mo
from January plus a new RM 10,000/mo from September derives RM 136,000 against a true
RM 104,000 — a 31% overstatement, shown confidently with its "working" displayed, and carried
into every future year. The RM 0 workaround was blocked by the editor's `amount > .zero`
validation. Spec §1 names "a new job in September" as one of the three problems the feature
exists to solve.

Fixed in `1837b93` with an `.editSource` mode that can set, clear and rename.

The same review also produced the highest-value item in the wave: a schema attribute-freeze
test (`bdd95c7`). `MigrationTests.schemaIsComplete` pinned model *names* only, so post-release
a rename like `grossIncomeSen → grossIncomeOverrideSen` would drop the column and silently lose
every user's income figure **with the entire suite green**.

---

## Verification gates

Run all of these before claiming this area works:

```bash
swift test                                        # 399 tests, 43 suites
./Scripts/typecheck-app.sh                        # app sources against the iOS SDK
./Scripts/build-app.sh                            # real xcodebuild build
./Scripts/run-app.sh /tmp/shot.png                # build, install, launch, screenshot
git diff <plan-base>..HEAD -- Sources/TaxKit      # must be EMPTY — the engine is untouched
grep -rn "epfSen\|socsoSen\|grossIncomeSen" Sources Tests App   # must be empty
grep -rn "import SwiftUI" Sources/                # must be empty
```

`golden-ya2025.json` must never be edited. Its last modification was during Plan 1; if it
stops reproducing, the projection is wrong, not the fixture.

### Environment notes (this cost real time — read before debugging the build)

- `xcodebuild` needs **both** `sudo xcodebuild -runFirstLaunch` **and** a simulator runtime
  matching the SDK. With Xcode 26.6 (SDK 26.5) and only the iOS 26.1 runtime installed,
  `xcodebuild` reports "Unable to find a destination" for *every* simulator destination,
  including `generic/platform=iOS Simulator`. Installing the iOS 26.5 platform fixed it.
- `Scripts/build-app.sh` had a latent bug this exposed: its device check matched a
  "Relio Test Phone" on the *26.1* runtime and skipped creating one on the newest runtime,
  then asked for `OS:latest`. Fixed in `0a69359` to be runtime-aware.
- `Scripts/run-app.sh` builds with `swiftc` + `simctl` and **never** calls `xcodebuild`, so it
  works even when the above is broken. It is what produces screenshots.
- The host display is headless, so the simulator cannot be tapped. Reaching a specific screen
  for a screenshot requires temporary scaffolding (a seeded store plus forced navigation);
  if you add any, revert it and verify it is absent from the diff before committing.
- Always read screenshots at the largest Dynamic Type size. Three separate real defects on this
  branch were visible only at AX5 and invisible to `swift test`: a nav title drawn over a
  section header, a menu picker truncating to "A mo…ly rate", and a `confirmationDialog`
  clipping as a popover.

---

## State at handoff

`master` at `ad92f4b`. Working tree clean. 399 tests passing. **Not pushed** — `master` is
ahead of `origin/master`; pushing is the user's call.

The income timeline is complete and integrated: two `@Model` types, a Kuala Lumpur day
calendar, a pure derivation, the store's write path and snapshot projection, the `TaxYear`
override, the view models, the Income screen, and onboarding asking for a monthly salary
and a start date rather than an annual total.

The spec's worked example — RM 113,950.00 for YA2025, with April blending to exactly
RM 8,800.00 from halves that round in opposite directions — is asserted at the derivation,
store, view-model and projection levels, and was confirmed rendering in the running app.

### Where to pick up

**Update, after `feat/income-identity-dedupe`.** Item 1 below (carried-forward item 8,
`IncomeSource` dedupe) is **done**, and with it the last carried-forward item that produced a
wrong number. `reconcile()` now has a production caller too, in `RootView`, so the whole sweep
— years, entries and income — runs on launch and on foregrounding rather than being dead code.
iCloud sync itself is still unverified end to end; that still needs two signed-in devices.
The two remaining items below, EPF/SOCSO relief and the income restore path, are unchanged.

`## Carried forward` in `docs/superpowers/plans/2026-08-25-income-timeline.md` is the
authoritative list — nine items. The three most consequential, in the order they matter:

1. **No dedupe for `IncomeSource` (item 8).** `reconcile()` covers years, entries, dependents
   and preferences but not income sources. Onboarding hard-codes a source named "Main job";
   if onboarding ever ran twice against a live CloudKit store — a second device, a reinstall —
   the user gets two "Main job" sources and **double-counted income for every year**, with both
   rows looking entirely correct. This is the one carried-forward item that produces a wrong
   number rather than a rough edge, and it becomes reachable the moment sync is exercised on a
   second device.
2. **EPF/SOCSO relief from salary (item 1).** The data is in place — `deductsEPF`/`deductsSOCSO`
   are per source and three-valued — so the work can know which sources contributed instead of
   assuming every ringgit was subject to an 11% deduction. Needs the statutory rate by age band
   and the RM 4,000 cap interaction. Spec §3 explains why this was deliberately not attempted here.
3. **No restore path for income (item 5).** `TaxStore` has both soft deletes and no restore, so
   deletions are unrecoverable from the UI, unlike relief entries which have `undoDelete()` and
   an undo toast.

Also unchanged from Plan 2: `reconcile()` and `recomputeAllDedupeKeys()` still have no
production caller, and iCloud sync is built but has never been verified end to end — that needs
two signed-in devices.

**Before running an existing install:** the schema was amended in place twice (pre-release,
per spec §9) without a version bump, so any build predating this work must be deleted from the
simulator or device first. `SchemaV1` is now frozen by a test that fails loudly with the
bump-and-migrate remedy in its message; after first release, the same edits require a
`SchemaV2` plus a `MigrationStage`.
