# Ledger — UX pass over the shipped iOS app

No plan document. This was an open-ended pass: "what's next, UX wise — there are still
so many issues". Worked directly on `master`, one atomic commit per finding.

Baseline at start: **568 tests**, 15 app source files. At the end of the pass:
**635 tests**, none removed.

---

## The tool that made the rest possible

This machine has no simulator tap automation. `simctl` installs, launches and
screenshots, and that is all — so the only screen anyone could ever look at was the one a
fresh install opens on, which is onboarding. Every other screen had been type-checked and
unit-tested and never seen.

That is the root cause of most of what follows. The first commit was a DEBUG-only
`DemoHarness` reading launch arguments: `-relio-demo` seeds a household, `-relio-empty`
completes onboarding and seeds nothing, `-relio-year` opens on another YA, and
`-relio-screen` opens any named screen or sheet. Almost every defect below was found by
looking at a screen for the first time.

---

## Two defect families, found repeatedly

### 1. The engine was more honest than the interface

TaxKit and TaxData were built and tested first, and the UI never caught up. In every case
the correct answer was already computed and simply not shown, or contradicted by the
screen above it.

| Built and tested | Surfaced |
|---|---|
| `counterfactual(entries:year:under:versus:)` | nowhere — Compare did not exist |
| `diff(from:to:)` | nowhere |
| `chargeableIncome`, `estimatedTax` | nowhere — Home showed only the last line of the sum |
| Requirement checks | nowhere — the Docs tab was a placeholder |
| Three-valued eligibility | "answer N questions" was a dead tap since the first build |
| `DependentDraft` and the whole dependant model | nothing in the app could add one, so five child reliefs were unclaimable |
| `verifiedOn` (spec §13 mitigation) | nowhere — there was no Settings screen |
| `softDeleteIncomeSource` | no restore existed, so spec §11.6's undo could not be honoured |
| `Document`, `DocumentFile`, `documentKinds`, `refreshDerivedFields` | every part of the attach loop except the attach — three screens could say a claim was short of a receipt and nothing could supply one |

### 2. A zero rendered as an achievement

Five instances, each telling the user something good about a state that was simply empty.

| Screen | Said | To someone who |
|---|---|---|
| Home headline | "RM 87,350.00 of relief still claimable" | had entered nothing — the sum of every cap in the rulebook |
| Relief detail | "Fully claimed — you have used all of this relief" | had entered no children (per-dependent cap = 0) |
| Relief detail | "Fully claimed" | is *granted* the relief automatically and claimed nothing |
| Docs tab | "Every claim is supported" under a green tick | had logged nothing at all |
| Compare | "These two years treat your entries the same" | had no entries to compare |

The child-relief one was the worst: it told a parent they had claimed all RM 2,000 of a
relief they had never been able to touch, discouraging the one action that unlocks it.

Worth noting: **the Income screen already got this right** — "Not recorded", never
"RM 0.00", with a footer saying why. The discipline existed in this codebase; it had not
reached the screens written since.

### 3. Copy-out-of-the-evaluation staleness

Three instances of one shape: a screen writes to the store, the evaluation reloads, and
the screens that *copy* out of it keep showing what they copied before. Documents after an
entry; Home after a dependant; Home after a household answer. Two were in code written
earlier the same session.

Found the second and third by auditing every model that writes to the store rather than
waiting to trip over them. `NewUserJourneyTests` now covers all three paths.

---

## Structural fixes, so a defect class cannot recur

| Encoded | Instead of |
|---|---|
| `AdaptiveRow` | the fourth hand-written `ViewThatFits` — every new row now stacks correctly at AX5 by construction |
| A rule written on `MoneyText` itself | fixing a fifth screen where a figure beside a label could not wrap as a sentence |
| `ProfileQuestionsViewModel.hasLoaded` | trusting every future caller to remember `load()` before `save()` |
| `ProfileQuestionsViewModel.answerable`, shared by Home's count and the sheet | two code paths counting the same questions and disagreeing |
| `DocumentsViewModel.rows`, shared by Home's count and the Docs tab | Home saying 8 while the screen it opened showed 6 |

---

## What is still not done

- ~~**Spec §11's three-column iPad layout.**~~ Built: `NavigationSplitView` on a regular
  size class, the tab bar on compact. `.tabViewStyle(.sidebarAdaptable)` was tried first
  and reverted — it adds a control whose expanded state cannot be reached without tapping.
- ~~**The zoom row-to-detail transition is unwatched.**~~ Watched, in the end.
  `-relio-delay` postpones the navigation so a screen recording catches it mid-flight, and
  the extracted frames show the detail growing out of the row rather than sliding in. The
  technique is in the README; it turns "cannot tap" into "cannot tap *interactively*",
  which is a much smaller limitation than it first looked.
- **VoiceOver and Reduce Motion.** The labels are unit-tested and read correct; nobody has
  heard them. This one is genuinely blocked — the simulator control tool cannot toggle
  either, and there is no device.
- ~~**Receipt capture.**~~ Attaching is built: photo library or Files, a content-addressed
  local file store, a ~30 KB thumbnail on the record, removal undoable. **OCR, MyInvois
  e-invoice parsing and the iCloud Drive file store are not** — files live on one device,
  which is what the app already is and what Settings already says.
- **The pickers themselves are untapped.** `PhotosPicker` and `fileImporter` need system
  UI. Everything they hand to is exercised by `-relio-attach`, which generates a real JPEG
  and drives the rest of the chain.

---

## Postscript: two "impossible" things that were not

Twice I recorded a limitation and twice it turned out to be narrower than stated.

**"The transition cannot be watched."** True that the simulator cannot be tapped; false
that the animation could not be seen. Navigation can be fired programmatically, and a
screen recording does not need anyone to tap. `-relio-delay` postpones the push so the
recording is already rolling; the extracted frames show the detail growing out of the row.

**"Receipt capture is a whole pipeline."** True of spec §9 entire — OCR, MyInvois QR,
iCloud Drive. False of the part that closes the loop: attaching a file so the requirement
check passes is a store method, a file store and a form section, and the rest of the
pipeline can arrive later without changing any of it.

The pattern in both: a real constraint was allowed to stand for a larger one. Worth
checking what exactly is blocked before recording something as blocked.
