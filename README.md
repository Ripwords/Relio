# Relio

Relio is a native Apple-platform app that helps Malaysian individual taxpayers track their tax relief — capture receipts, see what each relief still has room for, check that every claim carries the documents LHDN asks for, and compare how the rules changed between years.

Account-less and server-less. Data lives on your own devices and in your own iCloud.

> [!IMPORTANT]
> **Estimates only. This is not tax advice.**
>
> Every figure this project produces is an estimate. The relief caps and income bands in `Sources/TaxKit/Resources/Rules/` were transcribed from [hasil.gov.my](https://www.hasil.gov.my/individu/pelepasan-cukai/) on **23 August 2026** and each one carries its own `sourceURL` and `verifiedOn` date — but tax rules change, transcription can err, and your circumstances may not match what the engine models.
>
> **Verify against LHDN before you file, and consult a licensed tax agent for anything that matters.**

## Current state

The calculation core, persistence layer and view models are built and tested. Every iOS
screen has been installed, launched and read on the simulator in light and dark mode at
default and largest Dynamic Type sizes — see [Running the app](#running-the-app) for how,
and for what remains unverified.

| | Status |
|---|---|
| **TaxKit** — the tax engine behind Relio | ✅ Done |
| **TaxData** — SwiftData models, TaxStore, dedupe, reconciliation, income as a dated timeline (not one figure per year) | ✅ Done |
| **TaxPresentation** — tested view models | ✅ Done |
| iOS app — Home, Reliefs, entry CRUD, Income, onboarding | ✅ Built; every screen read on the simulator |
| Settings, Compare, Documents outstanding, Dependants | ✅ Built and read on the simulator |
| iCloud sync | Built, not verified end to end — needs two signed-in devices |
| Receipt capture, OCR, MyInvois e-invoices | Not started — the Docs tab lists what each claim still needs, but nothing can attach one yet |
| On-device AI assistant | Not started |
| iPad | Runs, and every screen is usable; not the three-column layout spec §11 describes |
| watchOS, macOS, widgets | Not started |

## What TaxKit does

A pure Swift package with no SwiftData, SwiftUI or platform dependency, so every Malaysian tax rule is testable with `swift test` and never needs a simulator.

- **Exact money.** Amounts are whole sen in an integer-backed `Money` type. There is no `Double` anywhere in the calculation path, and splitting an amount provably sums back to the original.
- **Verified rulebooks** for YA2023, YA2024 and YA2025 — 32 relief nodes and the 10 income bands per year, each citing its LHDN source.
- **Three-valued eligibility.** A fact the app has not asked about yields *"answer one question to unlock RM 4,000"*, never a silent "you don't qualify". Treating an unanswered question as a refusal is how a tracker quietly costs someone money.
- **A pure evaluator** handling flat caps, nested sub-limits, per-dependent ceilings with 50/50 spouse splits, and caps tiered on a fact such as property price.
- **Requirement checks** — a set difference between the documents attached to a claim and the kinds the relief requires.
- **Tax saved**, computed as a real difference between two tax calculations rather than headroom times a marginal rate, because relief that straddles a band boundary saves less than the higher rate implies.
- **Year comparison**, including a counterfactual that replays *your* entries under a different year's rules to report what a rule change is worth to you in ringgit.

### Example

For a married taxpayer on RM 128,000 with a non-earning spouse, three children and a first home:

```
Gross income            RM 128,000.00
Relief allowed        − RM  46,670.00
                        ─────────────
Chargeable income       RM  81,330.00
Estimated tax           RM   5,852.70
Still claimable         RM   5,563.20
```

Those are the recorded values in [`golden-ya2025.json`](Tests/TaxKitTests/Fixtures/golden-ya2025.json), so the suite fails if the engine ever stops producing them.

## What TaxData adds

TaxData is the SwiftData layer on top of TaxKit — models, `TaxStore`, dedupe, reconciliation — and it owns the facts TaxKit's evaluator is fed, including income.

- **Income that changes.** A raise in April or a second job in September is recorded once, as it happens. Relio derives the year's gross by pro-rating each month by days, so a mid-month raise blends correctly — and shows its working, because that figure drives every tax number in the app. Your own figure from your EA form always wins.

## Running the tests

```bash
swift test
```

Requires Xcode 26 or later (Swift 6.2 tools, iOS/macOS/watchOS 26 SDKs). No simulator needed — the engine has no platform dependency.

## Running the app

The iOS app's screens (`App/TaxTracker/`) are written and type-check against the iOS
simulator SDK. Three build scripts are available:

**Type-checking only (no simulator needed):**
```bash
./Scripts/typecheck-app.sh
```

**Hand-assembled simulator bundle (current workaround):**
```bash
./Scripts/run-app.sh
```
If you have a build from before the income timeline installed, delete it from the
simulator (or device) first. `SchemaV1` was amended in place rather than bumped — the
app has not shipped, so there was no store to migrate — and the old store either fails
to open against the new schema or lightweight-migrates and drops the year's income
figure with it. A fresh install starts at onboarding, which is the intended path.

This cross-compiles the package for the simulator, links the app sources against it,
stages TaxKit's resource bundle, ad-hoc signs and installs the bundle via `simctl`. The
script does not perform asset catalog compilation, entitlements processing or App Store
packaging, so a real `xcodebuild` build could still surface issues this path did not.

**Seeing a screen other than the first.** This machine has no simulator tap automation,
so for a long time the only screen anyone could actually look at was the one a fresh
install opens on — which is onboarding. That is why dead-end taps survived as long as
they did. A DEBUG-only harness fixes it: anything after `--` is passed to the app.

```bash
./Scripts/run-app.sh shot.png -- -relio-demo                      # seeded Home
./Scripts/run-app.sh shot.png -- -relio-demo -relio-screen docs   # any named screen
./Scripts/run-app.sh shot.png -- -relio-demo -relio-screen entry:LIFESTYLE:3000
```

`-relio-demo` seeds the household this README's worked example describes.
`-relio-screen` takes `home`, `reliefs`, `docs`, `settings`, `dependents`, `compare`,
`income`, `history`, `questions`, `entry`, `relief-picker`, `settings-household`,
`settings-contributor`, `relief:<CODE>` or `entry:<CODE>:<ringgit>`. `-relio-onboarding`
forces the welcome flow, `-relio-empty` completes it and seeds nothing (every empty state
lives there), and `-relio-year 2023` opens on another Year of Assessment. Combine with `xcrun simctl ui <device>
appearance dark` and `content_size accessibility-extra-extra-extra-large` to check both
of the axes the spec requires.

`RELIO_SIM_DEVICE_TYPE` drives the same script from an iPad:

```bash
RELIO_SIM_DEVICE="Relio Test Pad" \
RELIO_SIM_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-16GB \
  ./Scripts/run-app.sh shot.png -- -relio-demo
```

**Proper Xcode build (once first-launch is done):**
```bash
cp Config/Signing.example.xcconfig Config/Signing.xcconfig   # first time only
./Scripts/build-app.sh
```
This requires `sudo xcodebuild -runFirstLaunch` to have been run once on the machine
(for interactive admin authentication). Once that completes, `build-app.sh` is the
proper gate.

**Not yet verified:** VoiceOver and Reduce Motion (the simulator control tool cannot
toggle either) — the accessibility labels are unit-tested and read correct, but no one
has heard them. CloudKit sync
remains entirely unverified and requires two devices and a paid Apple Developer team.

To enable iCloud sync on a verified build, put your team id in `Config/Signing.xcconfig`
and point `TAXTRACKER_ENTITLEMENTS` at `App/TaxTracker/TaxTracker.entitlements`.

## Updating the rulebook

Malaysian reliefs change with each Budget. To add a year:

1. Add `Sources/TaxKit/Resources/Rules/ya-<year>.json`, transcribing from LHDN and setting `verifiedOn`.
2. Regenerate the relief-code constants:
   ```bash
   swift package --allow-writing-to-package-directory generate-relief-codes
   ```
3. Extend `shippedYears` in `RulebookIntegrityTests` and run `swift test`.

The integrity suite pins every cap and every band literally, checks that sub-limits fit inside their parents, that each band's cumulative base follows from the previous one, and that no relief code is ever deleted rather than retired. It will tell you what you got wrong.

## Documentation

- [Design spec](docs/superpowers/specs/2026-08-23-malaysian-tax-relief-tracker-design.md) — architecture, data model, sync, and the verified rulebook tables
- [Implementation plan](docs/superpowers/plans/2026-08-23-taxkit-foundation-and-rules-engine.md) — the 16 tasks that built TaxKit
- [Execution ledger](docs/superpowers/logs/2026-08-23-taxkit-execution-ledger.md) — every decision made during the build, including the bugs found and the ones deliberately deferred

Later work, newest first:

- [Income timeline design](docs/superpowers/specs/2026-08-25-income-timeline-design.md) and its [plan](docs/superpowers/plans/2026-08-25-income-timeline.md) — why income became a dated timeline rather than one figure per year. The plan's **Carried forward** section is the list of what is deliberately left undone.
- [Income timeline execution ledger](docs/superpowers/logs/2026-08-25-income-timeline-execution-ledger.md) — the rulings taken during that build, the verification gates, the simulator/`xcodebuild` environment traps, and where to pick the work up.
- [Persistence and iOS shell plan](docs/superpowers/plans/2026-08-24-persistence-sync-and-ios-shell.md) — SwiftData, `TaxStore`, the view models and the app.

## Not in scope

Direct submission to LHDN e-Filing (no public API exists), bank or email auto-import, shared household accounts, business income (Form B), non-resident tax treatment, and Android.
