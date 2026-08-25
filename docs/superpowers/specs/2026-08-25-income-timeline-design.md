# Income Timeline — Design

**Date:** 2026-08-25
**Status:** Approved design, pending implementation plan
**Amends:** `docs/superpowers/specs/2026-08-23-malaysian-tax-relief-tracker-design.md` §5 (data model), §11 (interface)

---

## 1. The problem

Relio stores one figure per Year of Assessment: `TaxYear.grossIncomeSen`. Onboarding asks
for "annual income" and the engine consumes it once, as `chargeable = gross − relief`.

That is wrong in three ways, and they compound:

1. **A salary changes.** A raise in April or a new job in September means no single monthly
   figure describes the year. The user has to compute the annual total themselves —
   arithmetic the app exists to do.
2. **The app keeps no record of when anything changed.** Next year the user starts again
   from nothing, and there is no way to check last year's figure against a payslip.
3. **Income is not one stream.** A second job, or occasional freelance work, is income the
   user must declare and Relio cannot represent at all.

Every figure Relio shows downstream — chargeable income, estimated tax, and the tax saved
by each relief — is computed from that one number. An income model that is merely
approximate makes every one of those figures approximate in a way the user cannot see.

## 2. What this does not change

**The tax engine is untouched.** Malaysian tax is assessed per Year of Assessment on a
total, so `evaluate(ruleSet:year:entries:)` still takes one `grossIncome` and still
computes chargeable income the same way. Everything in this design sits upstream of
`TaxYearSnapshot.grossIncome`. Plan 1's golden files stay valid, and `TaxKit` gains no new
dependency.

## 3. Non-goals

Named so scope does not drift:

- **Deriving EPF or SOCSO relief from salary.** Statutory employee EPF is 11%, which makes
  this tempting, but those reliefs are claimed today through logged entries and changing
  that is a separate piece of work with its own correctness questions. §7 records the data
  needed so it stays possible.
- **Form B treatment.** Business income, expense deduction and capital allowances remain
  out of scope, as the parent spec §2 states. §8 covers how Relio behaves when a user's
  income crosses that line rather than pretending it cannot happen.
- **Rental and dividend treatment.** Rental allows expense deduction and some dividends are
  exempt, so pooling them as if they were salary would overstate chargeable income. Same
  handling as §8.
- Payslip or EA-form import, multi-currency, and any withholding or PCB calculation.

## 4. Model

Two new `@Model` types in `TaxData`, following every constraint the existing models do:
every attribute optional or defaulted, every relationship optional, no `@Attribute(.unique)`,
soft delete throughout, `updatedAt` stamped by `TaxStore`.

```
IncomeSource                          IncomeRecord
├─ id: UUID                           ├─ id: UUID
├─ name          "Main job"           ├─ shape      recurring | oneOff
├─ kind          employment |         ├─ amountSen  monthly rate, or amount received
│                occasional |         ├─ effectiveFrom: Date
│                business |           ├─ note
│                rental | other       ├─ updatedAt, deletedAt
├─ deductsEPF:   Bool?                └─ source ────┘
├─ deductsSOCSO: Bool?
├─ endedOn:      Date?
├─ updatedAt, deletedAt
└─ records ───────────────────────────┘
```

### Decisions

- **One record type with a shape discriminator**, not two models. It keeps the mirrored
  relationship graph flat — the same reasoning that put `DependentYearStatus` inline on
  `Dependent` rather than making it an entity.

- **`effectiveFrom` means different things by shape**, deliberately. For a `recurring`
  record it is the date the rate takes effect; for a `oneOff` it is the date the money was
  received. One date field with a documented meaning per shape beats two fields of which
  one is always nil.

- **Sources are global, not per-year.** A salary set in April 2024 is still in force in
  January 2025. Hanging records off `TaxYear` would force the user to re-enter an unchanged
  salary every January, which is the original problem wearing a different hat. A year's
  income is derived by intersecting the timeline with that calendar year.

- **No `startedOn`.** The first `recurring` record's `effectiveFrom` is the start. `endedOn`
  is kept because it is the only thing that can stop a recurring rate — leaving a job has
  no "record" of its own.

- **`deductsEPF` and `deductsSOCSO` are `Bool?`, on the source.** See §7.

- **`kind` does not imply deductions and does not gate arithmetic.** It drives the warnings
  in §8 and nothing else.

## 5. Deriving a year's gross income

For Year of Assessment `Y`, over every live source and every live record:

**One-off records** contribute `amountSen` when `effectiveFrom` falls within calendar year
`Y`. They are independent of any recurring period — a bonus paid during a gap still counts.

**Recurring records** contribute for the span the rate was in force. A rate that starts at
`effectiveFrom` runs until the earliest of:

- the next `recurring` record on the same source — **exclusive**: the new rate takes effect
  on its own `effectiveFrom`, so the old rate is paid up to and including the day before;
- the source's `endedOn` — **inclusive**: that is the last day the source paid;
- 31 December of year `Y` — inclusive.

and is clipped at the start to the later of `effectiveFrom` and 1 January `Y`, inclusive.

These boundaries are stated to the day because the whole point of §5 is day-level
pro-rating: an off-by-one here is a real ringgit error in chargeable income, not a rounding
detail.

**Partial months pro-rate by days.** For each calendar month the span touches:

```
monthAmount = rate × (days of the span within that month) / (days in that month)
```

applied through `Money.applying(_:rounding:)` with `.halfUp`, per month, then summed. A
full month therefore yields exactly the rate with no rounding at all; only the partial
months at each end round, which is one sen of possible drift rather than a whole month's.
`Double` appears nowhere — this is a calculation path feeding chargeable income, and the
package bans it.

**Ordering is total.** Records sort by `effectiveFrom`, ties broken on `id.uuidString`,
the same discipline every other ordering in this codebase follows. Two rates on the same
date would otherwise make the derived figure depend on fetch order, and two devices could
disagree about a household's income.

**A rate with no successor and no `endedOn` continues indefinitely**, including into future
years. That is what "my salary is X" means.

## 6. The derived figure is a default, not the truth

`TaxYear.grossIncomeSen` becomes `grossIncomeOverrideSen`.

Relio derives the year's gross from the timeline, but the user's EA form is authoritative:
it includes benefits-in-kind, allowances, and income they never logged. When the override
is set, it wins; when it is nil, the derived figure is used.

The Income screen shows both — the derived total, and whether an override is in play — so
the user can see that Relio's figure and their EA form disagree, and decide which is right.

Without this, a month the user forgot to log silently understates chargeable income, which
inflates every "tax saved" figure on Home. That is the harmful direction: it tells someone
a relief is worth more than it is.

## 7. Statutory contributions belong to the source

A second employment deducts EPF and SOCSO. Occasional 4(f) income does not. And employment
does not guarantee it either — some contract roles, foreign employers and director
arrangements fall outside the statutory schemes.

So `deductsEPF` and `deductsSOCSO` live on `IncomeSource`, not on `TaxYear`, and both are
`Bool?`. **`nil` means "not asked yet"**, exactly as `Dependent.isDisabled` and the
disability flags do: storing `false` for an unasked question is how an app silently refuses
a relief and never explains why.

Nothing in this design reads those fields. They exist so that the EPF-derivation work named
in §3 can know which sources contribute, rather than assuming every ringgit of income was
subject to an 11% deduction — which would overstate EPF relief for anyone with side income.

`TaxYear.epfSen` and `TaxYear.socsoSen` are removed. They have never been read by anything,
and now that contributions are a property of a source, a per-year figure has no owner.

## 8. Where Relio stops being right, said out loud

Relio computes Form BE figures: employment income and occasional other income, aggregated
into one chargeable income.

Two situations take a user outside that, and the app must say so rather than produce a
confident number:

- **A source carried on as a business** — in practice, registered with SSM, or an activity
  resembling a business enterprise. This belongs on **Form B**, where business expenses are
  deductible. Relio's figure would be an overstatement of chargeable income and the wrong
  form entirely.
- **Rental or dividend income.** Rental allows expense deduction; some dividends are exempt.
  Pooling either as if it were salary overstates chargeable income.

A source whose `kind` is `business` or `rental` shows a persistent, quiet notice on the
Income screen and on any figure derived from it: Relio's estimate assumes Form BE, and this
income is treated differently. It does not block the user from recording it — their records
are their own — it stops the app being confidently wrong, which is the risk parent spec §13
names.

**Such sources are still counted in the derived total.** Excluding them would understate
chargeable income, which understates tax and overstates what every relief is worth — the
harmful direction. Including them overstates chargeable income for rental, where expenses
would have been deductible, which is the conservative direction and is what the notice
explains. A user who wants the other behaviour has the override in §6.

**Occasional freelance is not business income by default.** ITA 1967 §4(f) covers "gains or
profits not falling under any of the foregoing" and includes payments for part-time or
occasional work; unregistered casual freelance is declared on Form BE under other gains and
profits. The dividing line is whether the activity is carried on as a business, not whether
the work is freelance. Verify against hasil.gov.my before this reaches the rulebook, per
the parent spec's standard that every figure carries a source.

## 9. What changes downstream

| Layer | Change |
|---|---|
| `TaxKit` | **None.** |
| `TaxData` | `IncomeSource`, `IncomeRecord`; `TaxYear` loses `epfSen`/`socsoSen`, renames `grossIncomeSen` → `grossIncomeOverrideSen`; `TaxStore` gains their write path and the derivation |
| Projection | `TaxYearSnapshot.grossIncome` = override ?? derived. Same shape, different provenance |
| `TaxPresentation` | New `IncomeViewModel`; `OnboardingViewModel` writes a source instead of a year total |
| App | New Income screen; onboarding's income step changes |
| Home, Reliefs, detail, editor | **Unchanged.** |

**Schema.** `SchemaV1` has not shipped to any user, so it is amended in place rather than
bumped to `V2`, and `TaxMigrationPlan` keeps its single version and empty stage list. This
is the one moment that is free; after release the same change would need a migration stage.

## 10. Interface

The income step in onboarding stops asking for a year total and asks what it can actually
know: **the current monthly salary and the date it started.** That creates one source with
one recurring record. It remains fully skippable — parent spec §1 requires a receipt to be
loggable within 30 seconds without entering income at all.

A new **Income** screen, reached from the year menu, lists sources with their history, the
derived annual total per year, and the override. Adding a raise is one action: a new rate
and the date it took effect.

The derivation is shown, not just its result. A user who cannot see why Relio thinks they
earned RM 129,050 cannot tell whether it is right — and this figure drives every tax number
in the app.

## 11. Testing

- Boundaries to the day: a raise effective on the 1st (no partial month at all); a raise
  effective on the 15th (old rate paid through the 14th); a source ending on the 31st
  (that day counted); a source ending on the 1st (one day counted, not zero).
- Derivation: full-year single rate; mid-year raise; mid-**month** raise pro-rated by days;
  a job ending mid-year; a rate spanning a year boundary counted in both years correctly;
  one-off inside and outside the year; two rates on the same date resolving deterministically.
- Money: no `Double` on the derivation path; a full month yields exactly the rate.
- Override: set, cleared, and precedence over the derived figure.
- Three-valued deductions: `nil` survives a round trip and is not coerced to `false`.
- Projection: a household with two sources reproduces the expected `grossIncome`.
- Regression: Plan 1's golden files still pass unchanged, proving the engine is untouched.

## 12. Open items

1. Whether a user editing a past year's income should be warned that they may have already
   filed on the old figure.
2. Whether `endedOn` should be inferred when a new source of kind `employment` starts, or
   left explicit. Explicit for now — two concurrent jobs are real.
3. EPF derivation (§3) needs its own design, including the statutory rate by age band and
   the RM 4,000 relief cap interaction.
