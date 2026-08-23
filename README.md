# Tax Tracker

A native Apple-platform app that helps Malaysian individual taxpayers track their tax relief — capture receipts, see what each relief still has room for, check that every claim carries the documents LHDN asks for, and compare how the rules changed between years.

Account-less and server-less. Data lives on your own devices and in your own iCloud.

> [!IMPORTANT]
> **Estimates only. This is not tax advice.**
>
> Every figure this project produces is an estimate. The relief caps and income bands in `Sources/TaxKit/Resources/Rules/` were transcribed from [hasil.gov.my](https://www.hasil.gov.my/individu/pelepasan-cukai/) on **23 August 2026** and each one carries its own `sourceURL` and `verifiedOn` date — but tax rules change, transcription can err, and your circumstances may not match what the engine models.
>
> **Verify against LHDN before you file, and consult a licensed tax agent for anything that matters.**

## Current state

The calculation core is built and tested. **There is no user interface yet.**

| | Status |
|---|---|
| **TaxKit** — the tax engine | ✅ Done, 136 tests |
| Persistence, iCloud sync, iOS app | Not started |
| Receipt capture, OCR, MyInvois e-invoices | Not started |
| On-device AI assistant | Not started |
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

## Running the tests

```bash
swift test
```

Requires Xcode 26 or later (Swift 6.2 tools, iOS/macOS/watchOS 26 SDKs). No simulator needed — the engine has no platform dependency.

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

## Not in scope

Direct submission to LHDN e-Filing (no public API exists), bank or email auto-import, shared household accounts, business income (Form B), non-resident tax treatment, and Android.
