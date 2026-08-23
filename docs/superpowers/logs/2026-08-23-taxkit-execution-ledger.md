# SDD ledger — plan: docs/superpowers/plans/2026-08-23-taxkit-foundation-and-rules-engine.md

Spec: docs/superpowers/specs/2026-08-23-malaysian-tax-relief-tracker-design.md (read)
Branch: feat/taxkit-foundation
MERGE_BASE: 1d17731

## Pre-flight conflict scan

### Shared file / interface pairs

| Tasks | Produces → consumes | Finding |
|---|---|---|
| 1→2 | `Money` struct → `applying` appended to same file | clean |
| 1→3 | `Money` → `split` extension | clean |
| 1→4 | `Money` → `formatted` extension | clean |
| 1→5 | `Package.swift` → executable target + plugin added | clean |
| 4→8 | `Money.formatted()` → used in integrity failure messages | clean, T4 precedes T8 |
| 5→9 | `ReliefCode+Generated.swift` seeded 2 → regenerated 32 | clean; T5 step 9 restores the seed before commit |
| 6→7 | `ReliefRule` → `eligibility` property added | clean, resolved in plan self-review |
| 6→10 | `BracketTable` data → behaviour as extension in separate file | clean |
| 6→11 | `Cap`, `ReliefRule` → consumed by evaluator | **CONFLICT-1** (see rulings) |
| 7→12,13 | `deduplicated()` on Array → used in Evaluator | clean, same module |
| 8→9 | `RulebookIntegrityTests.shippedYears` [2025] → [2023,2024,2025] | clean |
| 8→16 | YA2025 structure → golden persona | clean |
| 9→15 | 3 rulesets → loader `availableYears` [2023,2024,2025] | clean |
| 10→14 | `BracketTable.taxSaved` → per-relief tax saved | clean |
| 11→12 | `effectiveCap(_:year:)` → `(cap:missing:)` tuple | clean, T12 states the signature change |
| 11→13 | `assess` eligibility block → replaced | clean |
| 11→14 | `EvaluationResult` → `totalOpportunity` added | clean, optional var defaults to nil in memberwise init |
| 11→15 | `evaluate` → called twice by `counterfactual` | clean |
| 11→16 | result types → `Codable` added | clean |
| 12→13 | cap questions → merged into eligibility | clean |
| 13→14 | `Eligibility` → gates `taxSaved` | clean |
| 14→16 | `totalOpportunity` → asserted in persona test | clean |
| 15→16 | `BundledRuleSetLoader` → used by golden tests | clean |
| 3→12 | `Money.split` → **no consumer in Plan 1** | **CONFLICT-2** (see rulings) |

### Task self-agreement

| Task | Finding |
|---|---|
| 1 | clean |
| 2 | clean |
| 3 | clean — hand-checked `split` against its own cases (2500/3, weights [1,3], negatives) |
| 4 | clean |
| 5 | clean — generator emits 0 codes pre-rulebook; step 9 handles it explicitly |
| 6 | clean |
| 7 | clean |
| 8 | clean — 24 top-level + 8 child codes; band widths verified against LHDN cumulative column |
| 9 | clean — 32 codes expected, matches the count in Task 8 |
| 10 | clean — all 9 boundary figures recomputed by hand against the published table |
| 11 | **CONFLICT-1** — `totals` test expects RM 3,500 |
| 12 | clean |
| 13 | clean |
| 14 | **CONFLICT-1** — `chargeableIncome` test expects RM 101,000 |
| 15 | clean |
| 16 | clean |

## Rulings

Ruling: CONFLICT-1 — the model has no notion of an automatically granted relief, so
`allowed = min(claimed, cap)` gives RM 0 for "Individual and dependent relatives", which
LHDN grants to every resident without a claim. Task 14's expected chargeable income of
RM 101,000 (gross 110,000 less 9,000) is therefore unreachable, and every child and
spouse relief would silently read as unclaimed. Amending the plan before Task 1: add
`automatic: Bool` to `ReliefRule`, grant the full cap when an automatic relief is
`.eligible`, and add `selfIsDisabled` / `spouseIsDisabled` predicates so the disabled
reliefs are gated rather than granted to everyone. Nine reliefs become automatic:
SELF_AND_DEPENDENTS, SPOUSE_ALIMONY, DISABLED_SELF, DISABLED_SPOUSE and the five CHILD_*
codes. Cost if wrong: the automatic set is a data-only decision in the JSON — a
mis-marked relief is a one-line fix per code, no engine change.

Ruling: CONFLICT-2 — `Money.split` is mandated by spec §4 rule 3 but has no production
caller in Plan 1; the 50% child-relief share uses `applying(0.5)`, which is correct
because it takes a share of a per-child cap rather than partitioning a whole. Keeping
`split` (spec-mandated, fully tested, real consumers in Plan 2: splitting one receipt
across categories, allocating a parent ceiling among sub-limits). A reviewer flagging it
as unused is correct and should be parked, not fixed. Cost if wrong: ~40 lines of tested
code unused until Plan 2.

Ruling: implementing on branch `feat/taxkit-foundation` in the primary working directory
rather than a separate git worktree. The repo is new, single-purpose, has no concurrent
work, and its only prior commits are docs; a branch satisfies the "never implement on
master" protection without the directory indirection. Cost if wrong: none material — a
worktree can be added later without touching history.

## Progress

Task 1: dispatched (sonnet, BASE 202e0f7)
Task 1: complete (commits 202e0f7..e251abb, review clean — spec ✅, quality approved)
Task 1: minor (deferred): .gitignore gained `.build/` — outside the brief's file list, housekeeping only
Task 1: minor (deferred): TDD red phase failed on a SwiftPM empty-target quirk, not the predicted "cannot find 'Money'" — green phase strong (6/6), red guarantee weaker than intended
Ruling: batching Tasks 2, 3 and 4 into ONE implementer dispatch. All three are transcription of fully-specified code into the same `Money` namespace (RoundingRule+applying, split, formatted), each with a complete test file and no cross-dependencies beyond extending Money. One review surface over the finished Money API is better than three, and it saves two dispatch+review cycles. Cost if wrong: a slightly larger diff for the fix loop to work over; risk is low because none of the code requires judgment.
Tasks 2-4: dispatched as one batch (sonnet, BASE e251abb)
Tasks 2-4: implemented (commits f8341c0, b892b5f, bae5679 — 21 tests passing); review dispatched
Task 2: complete (commit f8341c0, review clean — spec ✅, quality approved)
Task 3: complete (commit b892b5f, review clean — spec ✅, quality approved)
Task 4: complete (commit bae5679, review clean — spec ✅, quality approved)
Task 3: minor (deferred, plan-mandated): `abs(sen)` in split(weights:) traps on Int.min. Real but unreachable — Int.min sen is RM 9.2e16. Fix would be `Int(sen.magnitude)` with an overflow guard. Final review to triage.
Task 4: minor (fixed in docs, not code): spec said `ms_MY` locale; the code correctly uses an explicit "RM " prefix with `en_MY` grouping, which is deliberate and better. Spec §4.5, §11.7 and the plan's file map corrected; the Task 4 commit message retains the stale wording and is left alone.
Tasks 5: dispatched (sonnet, BASE bae5679)
Task 5: implemented (commit 22dd379, 25/25 tests). Deviation: `git checkout` could not restore the seed (file untracked); implementer rewrote it by hand.
Task 5: controller verification — ran ReliefCodeGenerator against a synthetic 2-code ruleset and diffed vs the committed seed: byte-identical, so the deviation carries no risk to Task 9's staleness test.
Task 5: controller verification — ran the generator over all 32 real codes plus a retired BOOKS alias: 33 valid Swift identifiers, no collisions, no keyword clashes. Task 9's regeneration will build.
Ruling: Task 5's Important finding (generator emits invalid Swift for a malformed code or a Swift keyword, with no validation) is plan-mandated — the brief's own generator code. Fixing rather than parking. No current breakage exists (I verified all 32 production codes generate valid, collision-free identifiers), but this generator's whole purpose is absorbing new relief codes each Malaysian Budget, which is precisely when a bad code would first appear, and the failure mode is a compile error inside a file marked "do not edit by hand". Fix is ~20 lines: regex validation, keyword backtick-escaping, collision detection, all failing loudly with exit(1). Verification by execution against deliberately-bad scratch rulesets rather than a new test target — the generator is a dev tool and Task 9's staleness test already guards its real output. Cost if wrong: ~20 lines of dev-tool code verified by manual runs rather than automated tests.
Task 5: fix round 1/5 dispatched (resumed original implementer)
Task 5: fix round 1/5 (4 addressed, 0 open; commits 22dd379..d4fdd0f). Implementer also caught a fifth case unprompted: MEDICAL_SERIOUS vs MEDICAL__SERIOUS both collapse to `medicalSerious` because split(separator:) drops empty components — subsumed by the general collision check.
Task 5: controller verification — exercised all four failure paths directly: invalid char exit 1, leading digit exit 1, SELF emits backticked `self` in both declaration and array element, double-underscore collision exit 1 naming both codes. Typechecked the backticked output against a ReliefCode stub: compiles.
Task 5: complete (commits c863896..d4fdd0f, review clean)
Task 6: dispatched (sonnet, BASE d4fdd0f)
Task 6: implemented (commit 186219a, 32/32). Controller verified: rate decodes via Decimal(string:), no decode(Decimal.self) anywhere, Cap has 4 cases (no sharedPool), automatic present, eligibility correctly deferred to Task 7.
Task 6: controller verification — all 12 rates used by the bracket table round-trip exactly through Decimal -> description -> Decimal(string:). Caveat recorded: "0.30" normalises to "0.3", so the values are equal but a byte-comparison of RE-ENCODED rulebook JSON would differ from the source file. Task 16's golden files encode EvaluationResult (which carries Money, not rates), so this does not affect them. Only a hypothetical future "re-encode the rulebook and diff it" test would trip on it.
Task 6: minor (deferred): relief(for:) recomputes allReliefs on every call. Immaterial at 32 reliefs; revisit only if it lands in a hot loop.
Ruling: removing Cap.none rather than deferring the reviewer's Minor. It is unreachable dead code whose nominalCeiling is Money(sen: .max), and Task 14 sums per-relief headroom with Money.+, which has an overflow precondition — so any future use would trap rather than degrade. Same species as the sharedPool case I removed pre-flight, and both shared and unbounded ceilings are already expressible as a parent cap with children. Plan amended so Tasks 11 and 12 do not reintroduce it. Cost if wrong: if a genuinely uncapped relief ever appears in a Malaysian Budget, the case must be re-added along with an overflow-safe headroom sum — roughly an hour, and the compiler will point at every site.
Task 6: fix round 1/5 dispatched (resumed original implementer)
Task 6: fix round 1/5 (1 addressed, 0 open; commits 186219a..9ef7e61)
Task 6: complete (commits d4fdd0f..9ef7e61, review clean)
Task 7: dispatched (sonnet, BASE 9ef7e61)
Task 7: implemented (commit 242bfe2, 45/45). Implementer correctly caught a real defect in my brief: Step 5's CodingKeys line predated the `automatic` amendment and would have dropped that field. Plan text corrected.
Ruling: Task 7's Important finding (no test for `any` with a failed child plus an unknown one) is plan-mandated — my brief's test list was incomplete. Fixing rather than deferring. The reviewer traced the implementation as correct, so this is purely a coverage gap, but it is the one path where a regression converts "answer a question to unlock RM 4,000" into "you do not qualify", which is the failure mode this whole three-valued design exists to prevent. Added that case, its all() mirror, and Codable coverage of all 17 predicate cases. Instructed the implementer NOT to touch the implementation and to escalate if any new test fails rather than adjusting the test to fit. Cost if wrong: three extra tests.
Task 7: minor (deferred): not(.satisfied) yields a generic "Condition must not hold" reason rather than a specific one. Uninformative but not misleading; no shipped relief uses a bare `not` at top level.
Task 7: fix round 1/5 dispatched (resumed original implementer)
Task 7: fix round 1/5 (2 addressed, 0 open; commits 242bfe2..efbdecd). All three new tests passed on first run against unchanged implementation code — the Kleene logic was already correct and is now pinned.
Task 7: complete (commits 9ef7e61..efbdecd, review clean)
Task 8: dispatched (sonnet, BASE efbdecd)
Task 8: implemented (commit 80711f4, 59/59; 24 top-level reliefs + 8 sub-limits = 32 nodes). Reported DONE_WITH_CONCERNS with three concerns, all three legitimate.
Ruling: concern 1 (CHILD_UNDER_18 missing "automatic": true) was MY defect, not the implementer's. My amendment script matched CHILD_UNDER_18 in Task 6's test fixture — earlier in the plan document — and inserted the flag there instead of in Task 8's rulebook. Implementer's fix accepted; plan corrected in both places. Cost if wrong: none, the shipped JSON and the plan now both read 9 automatic reliefs and the automaticSet test pins it.
Ruling: concern 2 (Package.swift gained `.copy("../../Sources/TaxKit/Resources/Rules")` on the test target) — the diagnosis was right but the remedy duplicates the rulebook into two bundles. Verified both TaxKit_TaxKit.bundle and TaxKit_TaxKitTests.bundle contain ya-2025.json. The integrity suite would then validate the test copy while Task 15's loader reads TaxKit's copy, so the suite would stop proving the SHIPPED data is valid — which is its only job. Replacing with an internal `RuleBundle.current` accessor inside TaxKit that both the tests and the loader go through. Cost if wrong: one extra four-line file; if `@testable import` ever fails to expose it the fallback is to make it public.
Ruling: concern 3 (collapsing a `+`-concatenated string into one interpolated literal to satisfy Comment's ExpressibleByStringLiteral) accepted as-is — a compile fix to my test code with no semantic change.
Task 8: fix round 1/5 dispatched (resumed original implementer)
Task 8: fix round 1/5 (1 addressed, 0 open; commits 80711f4..025b529). Clean build confirms ya-2025.json now exists in TaxKit_TaxKit.bundle only; Package.swift diff vs efbdecd is empty.
Task 8: controller verification — independent mechanical cross-check of the shipped ya-2025.json against the LHDN figures: all 32 relief caps match, all 10 bands match on lower/upper/rate/cumulative base, the automatic set is exactly the intended 9, and CHILD_UNDER_18 is gated at dependentAge max 17 (correctly "under 18", not "18 and under"). Full task review dispatched separately on opus with instructions to re-fetch hasil.gov.my and check relief by relief.
Task 8: full review (opus) — spec ✅, quality approved. Reviewer independently re-fetched hasil.gov.my and verified 32/32 relief nodes and 10/10 bands with NO figure discrepancy, matching my own mechanical cross-check. Two Important findings.
Ruling: Important finding 1 — SPOUSE_ALIMONY's predicate covered only the spouse half of LHDN item 14 ("Suami / Isteri / Bayaran alimoni kepada bekas isteri"), so a divorced claimant paying alimony was asked about a spouse they do not have and could never claim. Adding a `maritalStatus in [divorced]` branch AND removing `automatic` from this relief. The automatic removal is the important half: alimony is only claimable if actually paid under a formal agreement, so auto-granting RM 4,000 to every divorced claimant would overstate relief and understate tax — the harmful direction. Married claimants now see spouse relief as unclaimed headroom worth RM 760 rather than having it granted silently, which suits the app's framing. Fixing before Task 9 clones this file into two more years, which is materially cheaper than after. Cost if wrong: married users must confirm a relief that used to appear automatically; reversible by re-adding one JSON key.
Ruling: Important finding 2 — the integrity suite pinned only 6 of 32 caps, and cumulativeBasesAreConsistent validates the band arithmetic against itself, so a uniform shift of every base passes. For a task whose data IS the product that is too weak. Adding literal assertions for all 32 caps and the full 10-band table. Cost if wrong: two verbose tests that must be edited whenever LHDN changes a figure — which is exactly when a human should be looking.
Task 8: minor (deferred): nothingUnverified is vacuous today — no node sets `unverified`, so it can only fail if someone deliberately marks work in progress. Intent is right; it proves nothing now.
Task 8: minor (deferred): HOUSING_LOAN_INTEREST's nominalCeiling returns RM 7,000 regardless of tier. Task 12's resolver correctly returns zero when no tier matches (test `aboveEveryTier`), so this only affects diff/display surfaces in Plan 2.
Task 8: minor (parked): the yaRange 2025-2027 on HOUSING_LOAN_INTEREST encodes the sale-and-purchase-agreement window as a Year-of-Assessment window. The statutory relief runs three consecutive YAs from first interest payment, so a 2027 SPA is claimable into YA2029/2030. Inert while only YA2023-2025 ship; must be revisited when YA2026+ is added. Plan 2 concern.
Task 8: fix round 2/5 dispatched (resumed original implementer)
Task 8: fix round 2/5 (2 addressed, 0 open; commits 025b529..0a5c46c). Both new pinning tests passed on first run with no figure altered.
Task 8: complete (commits efbdecd..0a5c46c, review clean)
Note: regenerated briefs 9-16 from the current plan. They had been extracted before the automatic-relief, Cap.none, RuleBundle, alimony and pinned-figure amendments, so the stale copies would have sent implementers stale requirements.
Task 9: dispatched (sonnet, BASE 0a5c46c)
Task 9: implemented (commit 3c1a837, 67/67, generator wrote 32 codes). Two concerns, both legitimate: a Swift Testing compile fix to my multi-line #expect strings, and a correction to my ya2024Spot test which asserted CHILD_DISABLED.cap == .fixed when that relief is (and always was) .perDependent — the test was wrong, not the data.
Task 9: controller verification — independent cross-check of both new years against the LHDN deltas: YA2024 31 nodes all matching, YA2023 29 nodes all matching, bands byte-identical across all three years, ya-2025.json untouched, 32 generated constants.
Task 9: review NOT APPROVED — one Critical data error, one Important, one Minor.
Ruling: CRITICAL confirmed and it is MY error, not the implementer's. LHDN's YA2023 table item 10 reads "500 (Terhad)"; my delta list assumed the sports relief cap was flat across all three years and even listed LIFESTYLE_SPORTS in unchangedCapsAreStable, which is why nothing caught it. Verified directly in the raw page text I captured on 2026-08-23. Fixing the cap to RM 500 and, from the same source, correcting the YA2023 composition: gymnasium membership sat under Lifestyle that year and only moved into the sports relief in YA2024; YA2023's Lifestyle also lacks the upskilling-course sub-item. Removing LIFESTYLE_SPORTS from the flat-caps list and adding a sportsReliefTimeline test pinning 500/1000/1000. Cost if wrong: this is a real ringgit figure for YA2023 filers, so wrong in either direction matters — mitigated by pinning all three years explicitly.
Ruling: IMPORTANT rejected on evidence. The reviewer suspected parent eligibility for sports relief started in YA2024, citing a Ministry of Youth and Sports FAQ. LHDN's own tables are authoritative and disagree: YA2024 item 10 reads "diri sendiri, suami / isteri atau anak"; YA2025 reads "diri sendiri, suami / isteri, anak dan ibu bapa". Parents arrive in YA2025. No change. Cost if wrong: parent-claimed sports expenses would be refused for YA2024; the fix would be one eligibility branch.
Task 9: minor (deferred): disappearingCodesAreRetired is vacuous — all three removals go backwards in time, so the vanished set is empty by construction. The retirement mechanism it guards is untested until a real forward removal exists.
Task 9: fix round 1/5 dispatched (resumed original implementer)
Task 9: fix round 1/5 (1 addressed, 0 open; commits 3c1a837..70c665e). Implementer additionally proved unchangedCapsAreStable fails when LIFESTYLE_SPORTS is left in its list, confirming the guard works and only my list was wrong.
Task 9: complete (commits 0a5c46c..70c665e, review clean). All three Malaysian tax years now shipped and independently cross-checked.
Task 10: dispatched (haiku — plan carries complete code, pure transcription; BASE 70c665e)
Task 10: implemented (commit 5df5474, 77 tests in 9 suites). Controller verified: taxSaved is tax(before)-tax(after) not applying(marginalRate), bands.last preserved, no Double.
Task 10: review — spec ✅, quality approved. Reviewer independently recomputed all 9 boundary figures plus the cross-boundary taxSaved cases from LHDN's table by hand; every expectation correct.
Ruling: Important finding (taxSaved does not guard relief >= 0) accepted and extended. The reviewer framed it as a hypothetical caller bug; it is not hypothetical — SSPN relief is defined by LHDN as a NET deposit (deposits minus withdrawals in the year), so a withdrawal-heavy year legitimately produces a negative amount, and the rulebook's own notes say so. Following it through, Task 11 has the same exposure from the other side: `clamped(to:)` bounds only the top, so a negative entry would make headroom EXCEED the cap and inflate the opportunity figure the home screen leads with. Clamping in both places rather than asserting, because negative net deposits are valid user data, not a programming error. Task 11's plan amended before dispatch so it lands correct first time. Cost if wrong: a genuinely negative SSPN year is silently treated as zero relief rather than surfaced to the user as an anomaly — acceptable for Plan 1; Plan 2's UI can flag it.
Task 10: minor (noted, already handled): per-relief taxSaved figures are not additive across band boundaries. Task 14's design already computes the combined total with one call and has a test asserting total < naive sum.
Task 10: fix round 1/5 dispatched (resumed original implementer)
Task 10: fix round 1/5 (1 addressed, 0 open; commits 5df5474..40f7c80). Red phase confirmed the bug was real: before the clamp a negative SSPN year produced Money(sen: -38000) — a -RM380 "saving" on the home screen.
Task 10: complete (commits 70c665e..40f7c80, review clean)
Task 11: dispatched (sonnet, BASE 40f7c80)
Task 11: review — spec ✅, NOT approved. One Important finding, genuine over-claim bug.
Ruling: the evaluator aggregated children's RAW claimed amounts into the parent rather than their CAPPED allowed amounts. Traced it concretely: RM 1,500 logged against the RM 1,000 MEDICAL_CHECKUP sub-limit inside MEDICAL_SERIOUS's RM 10,000 ceiling gave the child allowed RM 1,000 correctly, but the parent summed the raw RM 1,500 and reported RM 1,500 of medical relief. LHDN allows RM 1,000. That overstates relief and understates tax — the harmful direction, and no existing test covered an over-sub-cap child. Fix separates the two totals: `claimed` stays raw for display, `allowed` sums children's capped amounts plus the parent's own floored claim, then clamps to the parent ceiling. The reviewer also confirmed the same line was already copied into Task 13's brief, so it would have propagated through two more tasks — both corrected. Cost if wrong: the parent ceiling could bind too early and understate relief, which is the safe direction and would surface immediately in the golden files.
Task 11: minor (deferred): an automatic relief overwrites any user-entered amount with the cap and the discarded figure goes nowhere — no unresolved entry, no note. Contradicts the never-silently-drop ethos applied to unknown codes. Low likelihood while no UI lets users log against automatic codes; revisit in Plan 2.
Task 11: fix round 1/5 dispatched (resumed original implementer)
Task 11: fix round 1/5 (1 addressed, 0 open; commits ad5c8cf..03d5309). Red phase reported parent.allowed = Money(sen: 150000) before the fix. Re-review traced the leaf case algebraically and confirmed behaviour is identical for reliefs with no children, and that the fix composes to arbitrary nesting depth.
Task 11: complete (commits 40f7c80..03d5309, review clean)
Ruling: the re-reviewer noted the automatic branch bypasses children and is "safe in practice, not by construction" — verified empirically that no automatic relief in any of the three years has sub-limits. Rather than spend a fix round on one test line, folding an `automaticRelievesHaveNoChildren` invariant test into Task 12's scope, which touches the evaluator anyway. Cost if wrong: none material; the test is green today and only fires on a future rulebook edit.
Task 12: dispatched (sonnet, BASE 03d5309)
Task 12: implemented (commit 97bb27c, 99 tests in 11 suites). One disclosed deviation: 5 static call sites qualified with Self. for Swift 6 strict mode, no assertions touched.
Ruling: the implementer flagged that an automatic per-dependent relief drops to .needsInfo if ANY single dependent's facts are incomplete, blocking the grant for all of them. Traced it: a parent with two children, one lacking a recorded birth date, would see RM 0 instead of the RM 2,000 earned by the child they did record. Fixing in Task 13, which owns that block. Granting the resolvable portion cannot overstate, because effectiveCap has already excluded the ambiguous dependent from the cap. Critically the exemption is scoped to per-dependent caps only — a fixed automatic relief like DISABLED_SELF must still wait for its answer, since granting it while we do not know whether the taxpayer is registered disabled would overstate outright. Added two contrasting tests to Task 13 pinning both halves. Cost if wrong: a household could see relief for a dependent whose details are incomplete; bounded by the cap already excluding them, so the exposure is zero ringgit by construction.
Task 12: complete (commits 03d5309..97bb27c, review clean — spec ✅, quality approved, no findings). Reviewer settled the split-vs-applying question: applying(rate:) is correct because a 50% child-relief share is not a pot divided among dependents; the other half belongs to a different taxpayer's return.
Task 13: dispatched (sonnet, BASE 97bb27c)
Task 13: complete (commits 97bb27c..d16bc0d, review clean — spec ✅, quality approved, zero findings). Reviewer traced all three PredicateOutcome mappings and all four branches of the per-dependent guard against the real rulebook, and established that .ineligible is structurally unreachable for per-dependent rules — so the isPerDependentCap grant exemption can only ever bypass .needsInfo, which is the documented safe case.
Task 14: dispatched (sonnet, BASE d16bc0d)
Task 14: complete (commits d16bc0d..0225e63, review clean — spec ✅, quality approved, zero findings). Reviewer independently recomputed tax(101,000) - tax(98,500) = RM 535 and confirmed it decomposes as RM 1,000 at 25% plus RM 1,500 at 19%, not a single marginal rate. Also walked the whole YA2025 rulebook to confirm only SELF_AND_DEPENDENTS is granted on an empty entry list, so chargeable income of RM 101,000 is right and nothing is silently over-granted.
Ruling: judgement call on whether a .needsInfo relief's headroom belongs in totalOpportunity. Keeping it in. The app's framing is "here is what you are leaving on the table", and a .needsInfo relief is precisely money the user may be able to recover by answering one question — excluding it would make the headline understate the upside and bury the prompt. Those reliefs render as visible prompts rather than as banked figures, so the user is not misled. Reviewer independently reached the same conclusion. Cost if wrong: the headline total assumes questions that may resolve unfavourably; a user who answers "no" sees the figure drop, which is the safe direction and is explained by the prompt they just answered.
Task 15: dispatched (sonnet, BASE 0225e63)
Task 15: implemented (commit 9a985ed, 125 tests in 14 suites, no deviations). Review: spec ✅, approved with two Important fixes.
Ruling: Important 1 — the counterfactual's sort is unstable and the tie is reachable. The reviewer found concrete pairs in the shipped data: DISABLED_SELF, DISABLED_SPOUSE and INSURANCE_EDU_MEDICAL all moved by exactly RM 1,000 between YA2024 and YA2025, and MEDICAL_LEARNDIS and CHILD_DISABLED both by RM 2,000. An OKU household would therefore see the Compare screen potentially reorder between launches. Adding a code tie-break. Confirmed it does NOT reach Task 16's golden files, which encode EvaluationResult only. Cost if wrong: ordering is cosmetic; a wrong tie-break rule reorders two rows.
Ruling: Important 2 — diff compares only cap.nominalCeiling, so a tiered cap whose lower band moves while its ceiling holds reports no change at all. Not triggered by the shipped years (HOUSING_LOAN_INTEREST is the only tiered relief and exists only in YA2025), but that relief is live and its RM 500,000-750,000 band is exactly the kind of thing a Budget adjusts. Reporting a same-ceiling restructure as a conditions change, guarded so it cannot double-emit alongside capChanged. Cost if wrong: an extra conditionsChanged row on the Compare screen.
Task 15: minor (deferred): a shipped year whose bundle resource is missing reports .noRulesForYear rather than distinguishing a packaging defect from an unshipped year. Only reachable via a build defect.
Task 15: minor (deferred): availableYears is a hardcoded default rather than derived from bundle contents, so it must be kept in sync by hand when a year is added.
Task 15: fix round 1/5 dispatched (resumed original implementer)
Task 15: fix round 1/5 (3 addressed, 0 open; commits 9a985ed..7914821). tiesAreBrokenByCode passed non-vacuously: DISABLED_SELF and DISABLED_SPOUSE both appear at RM 1,000 each and now sort in code order. Re-reviewer confirmed the comparator is a valid strict weak ordering and the capStructureChanged guard cannot double-emit.
Task 15: complete (commits 0225e63..7914821, review clean)
Task 16: dispatched (sonnet, BASE 7914821)
Task 16: complete (commits 7914821..992efa7, review clean — spec ✅, quality approved, zero findings). Reviewer independently recomputed the per-dependent caps, the medical sub-limit, the insurance parent/child excess containment and the missing-document requirement against the rulebook. Confirmed the 16-year-old in pre-tertiary study correctly falls under CHILD_UNDER_18 rather than CHILD_PRE_TERTIARY, with the 50% claim applied.
ALL 16 TASKS COMPLETE. 131 tests in 15 suites.

## Final whole-branch review (opus)

Found one Critical and two Important that all 16 task-scoped reviews missed, because each saw only its own slice.
Ruling: CRITICAL — `allowed` never consulted eligibility outside the automatic branch, so an ineligible relief with entries still reduced chargeableIncome and understated estimatedTax. Only taxSaved was gated, which is why it looked handled. Both existing ineligibility tests passed `entries: []`, so it was invisible to them. Verified by reading the source myself before dispatching. Fixed: .ineligible now forces allowed to zero while claimed stays raw for display. Red phase confirmed RM 900 of relief and RM 225 of tax leaking. Cost if wrong: none — this can only reduce claimed relief, the safe direction, and .needsInfo is explicitly excluded so the three-valued design is intact.
Ruling: IMPORTANT — counterfactual built lines from allAssessments (parents and children) then totalled those same lines, double-counting every sub-limit against an explicit doc comment forbidding it. MEDICAL_LEARNDIS rose RM4,000 to RM6,000 in YA2025, so RM6,000 of spend reported RM4,000 of difference instead of RM2,000, and taxDifference disagreed with it on the same screen. Fixed: total now comes from top-level assessments only. Cost if wrong: the Compare screen's headline understates; the per-line rows are unchanged and still show every sub-limit.
Ruling: IMPORTANT (wiring) — Facts.propertyPriceSen and TaxYearSnapshot.lastClaimedYear were written but never read, so any claimFrequency predicate could never resolve. Wired both through facts(). Absent claim history maps to .unknown, not .neverClaimed: the app cannot know what a user claimed before adopting it, and assuming "never" would over-grant a once-every-two-years relief.
Final fix wave: complete (commits 992efa7..76ba4ea, all 4 findings ADDRESSED, no blockers). 136 tests, 15 suites, green.
Note: the CHILDCARE correction is the Critical fix working as intended. The persona's youngest dependent is 7 and LHDN's childcare relief is for a child aged 6 and under, so the previous golden recorded RM 2,400 of relief the household was never entitled to. Chargeable income rose by exactly that amount and the tax recomputes correctly. The fix caught an invalid claim baked into my own test persona.
Ruling: parked — an ineligible relief reports headroom equal to its cap while allowed is zero, so the engine still describes an unclaimable relief as headroom. No total is inflated (taxSaved is nil and combinedHeadroom filters on taxSaved != nil), so no ringgit is wrong today. Parking rather than opening a second fix wave. Plan 2 must key its opportunity list off `eligibility` and `taxSaved`, never `headroom`. Cost if wrong: a UI built on headroom alone would advertise reliefs the user cannot claim.
Ruling: parked — Facts.propertyPriceSen is now populated but no predicate reads it; TieredFact reads the snapshot directly. The wiring is harmless and makes the field available to a future propertyPrice predicate. Cost if wrong: one unused field.
Ruling: parked — a `.not` wrapped around a dependent predicate would get inverted existential semantics under Ruling A. Zero `not` ops exist in any shipped rulebook, verified by grep. Cost if wrong: a future rulebook author using `not` over a dependent condition would get a silently wrong result; Plan 2 should add a rulebook-integrity test forbidding `not` over dependent facts until the semantics are defined.
Ruling: parked — BREASTFEEDING's taxSaved went from RM 190 to absent, correct because the relief is now ineligible for this persona. Disclosed in the totals but not called out per-relief in the fix report. No action.
