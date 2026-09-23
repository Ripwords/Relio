# SDD ledger — plan: docs/superpowers/plans/2026-09-23-receipt-reading.md

Spec: `docs/superpowers/specs/2026-09-23-receipt-reading-design.md`
Branch: `feat/receipt-reading`, worktree `.claude/worktrees/receipt-reading`, from `master` at
`9476a18`.
Commit range: `git log --oneline 9476a18..HEAD` — 21 commits, `8715f5e..23b9281`.
Executed with subagent-driven development — a fresh implementer per task, a spec+quality
review after each, a fix loop, then this close-out.

**Test counts, measured directly (not taken from an earlier note):**

- **At merge-ready HEAD** (after the final review's fixes): **789 tests in 96 suites, all
  passed**. See "Final review" below.

- **Before** (`9476a18`, in a detached scratch worktree, `swift test`): **669 tests in 82
  suites, all passed.**
- **After Task 13** (`23b9281`, `swift test`): **777 tests in 95 suites — 775 passed, 2
  failed.** The 2 failures are `Tests/TaxCaptureTests/AdapterTests.swift`'s
  `"Vision reads the sample receipt, and the parser finds its total"` and
  `"a page with no text layer is OCR'd"`, both with Vision's
  `.e5rtError("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options
  call failed", 13)`. This is an environment issue on this Mac's on-device compute backend,
  not a code regression:
  - The `AdapterTests` suite does not exist at `9476a18` (the plan created it in Task 7), so
    there is nothing to compare against at the base commit.
  - The same two tests were re-run directly at `d7eeb96` (Task 12's HEAD, one commit before
    Task 13) in a scratch worktree during Task 13 and failed identically — confirmed in
    `task-13-report.md` and reconfirmed here: the failure is present at both `d7eeb96` and
    `HEAD`, so nothing in Task 13's commit introduced it.
  - Task 7's report recorded the same error signature as *transient*, passing after the
    on-device model cache warmed. On this run it did not clear after three retries
    (`task-13-report.md`) and is still failing now — persistent this session, not a one-off.
  - `./Scripts/typecheck-app.sh`: `Type-check succeeded (29 files).` One pre-existing
    warning, `App/TaxTracker/Income/IncomeView.swift:357` (unused `let record`) — that file
    is not touched anywhere on this branch (confirmed by `git diff 9476a18..HEAD --
    App/TaxTracker/Income/IncomeView.swift` being empty), so the warning predates this plan.
  - `git status --short`: clean before this ledger was written.

---

## Task-by-task

### Task 1 — `TaxCapture` scaffold, readings, and amounts on a till line

New target `TaxCapture` (depends on `TaxKit` only), `Reading<Value>`/`ReadingSource`/
`ReadingConfidence`, `OCRLine`, and `ReceiptAmount.amounts(in:)` reading the shapes a
Malaysian till prints (`RM12.50`, `12.50 RM`, `5.00-`), rejecting dates/rates/weights, and
refusing an amount that would overflow `Int`. Commits `8715f5e`, `2527b7c`.

**Differed from the plan.** The implementer hit `IncomeDerivationTests.noBinaryFloatingPoint
InSources`, a whole-repo guard banning `Double`/`Float` outside one named exemption, which
the plan never accounted for — confidence scores and Vision page geometry are `Double`
throughout the later tasks. Ruling: exempt `Sources/TaxCapture/` from the guard **except**
`Sources/TaxCapture/Parsing/ReceiptAmount.swift`, which stays covered, since that is the one
file in the target that turns receipt digits into `Money`. Review found the guard's pin
checked the unfiltered file list (would not catch a widened skip); fixed in the same fix
round with a pinning test. Also from this task on, commits carry no `Co-Authored-By`
trailer — a harness instruction received mid-run overrides the plan's commit blocks; the
first commit, `8715f5e`, already has one and was left as is (no history rewrite).

### Task 2 — Dates on a receipt line

`ReceiptDate.dates(in:now:)`/`.noon(_:_:_:)`, day-first, `Asia/Kuala_Lumpur`, English and
Malay month names, future/>7-years-back rejected, ambiguous day≤12-and-month≤12 flagged.
Commit `738ab61` (682/682 tests). Reviewed clean; three Minors parked (return order for two
dates on one line, duplicated 2-digit-year normalisation, no exact-7-year-boundary test) —
the first was resolved by Task 3's fix below.

### Task 3 — Rows, and the parser that reads total, date and vendor

`Phrase` (whole-word label/keyword matching), `RowAssembler.lines(from:)` (rejoins a row
Vision splits into fragments), `ReceiptParser.parse(_:now:) -> ReceiptFields`, and the
13-fixture JSON corpus (supermarket, pharmacy, bookshop, clinic, BM-only, Chinese-vendor,
rounding, service-charge, unlabelled-total, no-total, conflicting-totals, ambiguous-date,
future-date). Commits `370c359`, `060ec1b` (693/693 tests), fix `d8cec5e`.

**Differed from the plan.** Review found `readDate` picked among a line's several dates by
`ReceiptDate.dates(in:)`'s return order (iso→numeric→named) rather than the order they are
printed, and that `RowAssembler` could merge two printed dates onto one line. Fixed at the
source: `ReceiptDate.dates(in:now:)` now returns dates sorted by match start (textual
order), which also closed Task 2's parked Minor (a) in the same fix.

### Task 4 — The MyInvois QR link

`MyInvoisLink(_:)?` parses `{portal}/{uuid}/share/{longId}`, accepting only
`myinvois.hasil.gov.my`/`preprod.myinvois.hasil.gov.my`, no query, no fragment, `uuid`
10–40 alphanumeric characters, `longId` at least 10. Commit `be6fa5a` (698/698 tests).
Reviewed clean, 0 Critical/Important. Ruling: the plan's 200-character cap on `longId` was
kept even though spec §4 only says "at least 10" — a real longId is far shorter and the
payload is attacker-controlled; noted rather than editing the spec (worst case, a genuine
e-invoice with an implausibly long `longId` is not recognised as one, and the receipt still
reads by OCR).

### Task 5 — Suggesting reliefs from a receipt

`ReliefSuggester.suggest(vendor:text:in:)`, a keyword table mapping vendor/line words to
relief codes, filtered to codes present and user-claimable in that year's rulebook, at most
three, never automatic. Commit `6a8a534` (706/706), fix `6a88ddf` (707/707).

**Differed from the plan.** Review found "PTPTN" suggested SSPN, but most PTPTN receipts
are loan *repayments*, which carry no relief. Fixed by dropping "PTPTN" from the SSPN
keyword row (kept "SSPN" itself, which a real deposit slip prints) and pinning it with a
test that a PTPTN repayment line suggests nothing. The 9-line fix diff was re-reviewed by
the controller reading the diff directly rather than dispatching a second review agent.

### Task 6 — Normalising what was captured, and a receipt to test with

`ImageNormaliser`/`ImageNormalising` (2000 px long edge, JPEG, metadata stripped, 320 px
thumbnail under 30 KB), `NormalisedDocument`, and `SampleReceipt` (DEBUG-only, renders a
receipt PNG/JPEG/PDF and a QR with CoreGraphics/CoreImage for tests and screenshots).
Commit `093f5d3` (714/714 tests; `typecheck-app.sh` green).

**Differed from the plan.** `SampleReceipt.swift` is the first file in the package to
cross-compile an Objective-C framework (`CoreImage`) for iOS; `Scripts/typecheck-app.sh`'s
`swift build` passed the SDK/target only via `-Xswiftc`, which does not reach the Clang
importer, so `CoreImage.h`'s iOS-only `#import <OpenGLES/EAGL.h>` failed against the host
macOS sysroot. Patched the script with `-Xcc -isysroot`/`-Xcc -target` — accepted as
tooling, not a task-scope violation, since without it the plan's own gate cannot run.
Review Focus 1 (`orientationIsApplied`) passed clean. Two Minors parked: the orientation
test proves a swap happened, not the exact direction (5/7/8 unexercised); `pageImages` can
legitimately be `[]` when a PDF's page one fails to render (Task 8 must tolerate it, and
does — see Task 8).

### Task 7 — Reading text and QR codes for real

`VisionTextReader` (`.accurate`, en-US/zh-Hans/zh-Hant, language correction off),
`VisionBarcodeReader` (QR only), `PDFTextReader` (text layer first, OCR fallback capped at
5 pages — Review Focus 5, `ocrFallbackStopsAtFivePages`, exercised against a real 40-page
image-only PDF and asserted to call the reader exactly 5 times). Commit `89a3d80` (721/721
tests; watchOS build clean with `--sdk` added as a top-level flag, since `-Xswiftc -sdk`
alone does not reach the Clang importer on this toolchain — same class of fix as Task 6's).

**What Task 7 actually saw, for the final review.** On this machine the first
multi-language (`en` + `zh`) `RecognizeTextRequest` failed twice with the same
`e5rtError … precompiled_compute_operation` seen at the end of this plan, before the model
cache warmed — a first-run user could see one failed read, and the pipeline (Task 8) must
degrade to "could not read" rather than crash; a retry worked that session. Later in the
plan (Task 13, and again in this close-out) the same error became persistent rather than
transient on this Mac — see the header's test-count note. Reviewed clean, 0
Critical/Important; two Minors parked (no `Task.checkCancellation()` in the PDF page loop;
bare 0.8 JPEG quality).

### Task 8 — The pipeline

`DocumentPipeline` actor: normalise → hash (via the caller's `DocumentFileStore.write`,
per the plan's deviation #1 — no separate SHA-256) → thumbnail → barcode → text → parse →
(later, Task 13) model. Never throws except when the input cannot be decoded at all.
Commit `2ea073c` (731/731 tests; `typecheck-app.sh` green). Reviewed clean, 0
Critical/Important; two Minors parked: one barcode throw aborts the QR scan of *later*
pages of a multi-page scan; a generic catch records `CancellationError` as a soft stage
failure, so cancelling a read does not stop it early — the caller (Tasks 10/12) must drop a
stale result, which Task 12's fix round 2 later did.

### Task 9 — The store records what was read, and finds claims a receipt already supports

`DocumentDraft` gained `ocrText`/`eInvoiceUUID` (no schema change — the `Document` columns
already existed); `TaxStore.claimsSupported(byHash:orEInvoiceUUID:excludingEntry:)` and
`isFileReferenced(hash:)`. Commit `7548b09` (740 tests in 92 suites).

**Differed from the plan, mechanically.** The brief's single chained pipeline in
`claimsSupported` and its inline `.sorted { switch … }` closure both timed out the Swift 6
type checker; broken into explicitly-typed intermediate bindings and a named comparator
with identical filter/sort semantics (earliest `spentOn` first, undated last, ties on
`entryID.uuidString`) — no interface or behaviour changed. Reviewed clean; two Minors
parked (a documentation contrast that nothing currently sets; a hash-path detail).

### Task 10 — A receipt starts the entry

`EntryEditorViewModel.prefill(from:files:) -> Bool` (a method, not an initialiser, per the
plan's deviation #2 — writing the pending file can fail), pending-attachment state,
attach-on-save, cleanup-on-cancel unless another claim uses the file (Review Focus 2,
`cancelKeepsAFileAnotherClaimUses`), and the year-mismatch flag (Review Focus 3,
`receiptFromAnotherYearIsFlagged`). Commit `9a880b2` (752 tests), fix `9626e9d` (753 tests).

**Differed from the plan.** Ruling: added an attach-failure/retry test beyond the plan's
verbatim test file — the `newEntryID` design exists specifically for that path and nothing
in the brief pinned it. Re-review (controller reading the diff, not a fresh agent) found
both addressed.

### Task 11 — Attaching a receipt to an existing entry reads it too

`EntryEditorViewModel.attach(_:files:) -> AttachResult`, the amount offer
(`receiptAmountOfferText`/`useReceiptAmount()`/`dismissReceiptAmountOffer()`), and removal
of `attachDocument(kind:contentHash:byteCount:uti:thumbnail:)`. Commit `42d7b74` (759
tests), fix `80ea30f`.

**Intentional red type-check, as the plan specifies.** Removing `attachDocument` here is
what breaks `App/TaxTracker/Entries/EntryEditorView.swift:291`, the app's one remaining
call site — `./Scripts/typecheck-app.sh` failed with three compiler errors at exactly that
line after this task's commit, and stayed red until Task 12 rewrote the call site. The plan
chose this order deliberately: `attachDocument` existing only to be deleted one task later
would be a worse shape than one commit in history where the app target does not build
(which only matters to a `git bisect`). Fix round: review asked for a test on orphan-file
cleanup when the entry the attach targets has vanished (soft-deleted) by the time the
attach resolves — added, both outcomes (deleted / kept because another document
references the same hash) asserted; re-reviewed by the controller directly (32 test lines,
no source change).

### Task 12 — The app scans, reads and prefills

`CapturePipeline`, `DocumentCameraView` (`VNDocumentCameraViewController`,
`isSupported` gates it off the simulator), `ReceiptCaptureModifier` (camera sheet, Photos,
Files, all through `CapturePipeline.read`), the "Suggested from the receipt" +
"All reliefs" split in `ReliefPickerView` (shown only when there is a suggestion, never a
single-option control), the receipt section, unconfirmed marks, and the README's "Reading
receipts" section. Commits `cdf6ae0` (762 tests, `typecheck-app.sh` green, 29 files), fix
`54f3620` (`Scripts/run-app.sh`), fix `d7eeb96`.

**What Step 12 (screenshots) actually saw.** `run-app.sh` could not build the app at all at
first, for the same class of Clang-importer gap as Tasks 6/7 — `PDFKit`'s
`PDFKitPlatform.h` resolved against the macOS SDK and failed on `#import <UIKit/UIKit.h>`.
Patched with the same `-Xcc -isysroot`/`-Xcc -target` flags `typecheck-app.sh` already
carried (own commit, `54f3620`, since it is outside Task 12's file list but a binding
gate). With that fixed, all seven screenshots were taken and read:

- `scan.png` — "New entry" sheet, receipt thumbnail, **Amount 71.90** (no mark), **Vendor
  MPH BOOKSTORES SDN BHD** (no mark), **Spent on 7 Mar 2025** with an orange
  ambiguous-date mark (07/03 genuinely reads either way — correct), Relief "Choose…", the
  "Relio was not sure of the marked fields…" footer, "Choose a relief." prompt. OCR worked
  on the simulator — fields were not blank.
- `scan-einvoice.png`, and the einvoice runs of `scan-ax5.png`/`scan-ax5-dark.png` — same
  fields as `scan.png`, thumbnail visibly contains the drawn QR block, but the "MyInvois
  e-invoice" badge did **not** appear. Traced to `VisionBarcodeReader.qrPayloads(inImage:)`
  returning no payload for the synthetic QR **on the simulator specifically** — the
  identical code path is proven correct by `DocumentPipelineTests`'s
  `"a MyInvois QR sets the e-invoice ID"` running the real Vision framework on macOS in the
  passing suite, and Task 8's barcode-failure handling is deliberately soft (the reading
  still succeeds; only `eInvoiceUUID` stays `nil`). No app or pipeline code was changed to
  force a result. The document camera itself never ran — the simulator has none.
- `scan-picker.png` — "Choose a relief" with a one-row "Suggested from the receipt" section
  ("Lifestyle — books, computer, …") above "All reliefs". Ruling: a one-item suggestion
  section is allowed under the no-single-option-control rule — the picker as a whole is
  still a real choice (accept the suggestion or pick something else); the rule's own
  wording scopes it to hiding the header when the list would be *empty*.
- `scan-2024.png` — adds the year-mismatch line exactly as specified, inside the Receipt
  section, not truncated.
- `attached.png` — an existing entry's Documents section with one row, no amount-offer UI
  (none is due on a freshly opened entry), no UUID/hash visible.
- `scan-ax5.png` / `scan-ax5-dark.png` — checked the right edge of every row and the bottom
  of the receipt section and its footer explicitly in both: text wraps to multiple full
  lines and completes cleanly before the card edge, no clipping, no "…" truncation beyond
  the copy's own placeholder ellipsis, both themes re-colour correctly with no
  white-on-white/black-on-black.

Review (fix round 2) found reads were not dropped when the editor closed mid-scan (Task
8's parked obligation, now due): `ReceiptCaptureModifier` ran the read from a bare `Task`
nothing cancelled. Fixed with a tracked `readTask`, cancel-on-new-read and
cancel-on-disappear, and a `Task.isCancelled` guard before `onRead`/`onError` fire; commit
`d7eeb96`. Re-reviewed by the controller directly (21 lines, one file).

### Task 13 — The on-device model, fact-checked

`ReceiptModel` protocol, `ReceiptModelCheck` (`question(for:in:)`,
`answer(from:to:within:)` — races the model against a 3 s timeout, abandoning it if it
never returns — `apply(_:to:question:)` — the fact-check: a vendor must appear in the OCR
text, a candidate index must be in range, a relief must be one offered), and
`FoundationModelsReceiptModel` (`init?()` nil unless `SystemLanguageModel.default
.availability == .available`), wired into `DocumentPipeline.read` as the last stage.
Commit `23b9281`. Reviewed clean, 0 Critical/Important.

**What Step 7 actually saw.** `scan-model.png` (via `-relio-demo -relio-scan` with the
model wired in) was read field-for-field against Task 12's `scan.png`: **identical** —
same thumbnail, Amount 71.90 (no mark), Vendor MPH BOOKSTORES SDN BHD (no mark), Spent on
7 Mar 2025 (ambiguous mark), "Choose a relief." This is the expected outcome, not a
regression: the sample receipt parses with one confident total and a company-suffix
vendor, so `ReceiptModelCheck.apply` has nothing to change — the fact-check leaves an
already-confident reading untouched by design.

**Whether the model ever ran, exactly.** A temporary `print` confirmed
`FoundationModelsReceiptModel.init?()` succeeded on this simulator
(`[Task13] on-device model available: true`, removed before committing) — Apple
Intelligence is available here and the model object was constructed; that it was then asked a question was not observed.
**What was not verified is whether an answer arrived within the 3 s timeout on this
particular scan** — the review's own parked Minor notes `ReceiptModelCheck.answer` does not
observe the caller's cancellation, and since a model relief choice only ever reorders
`suggestedReliefs` in the relief picker (never the Relief field itself, which stays
unselected regardless), `scan-model.png` cannot show whether the model's answer was used
or simply timed out — a bookstore receipt with one confident total and vendor gives the
fact-check nothing to change either way. Model tests (`ReceiptModelTests`) cover the
timeout and fact-check logic directly against stubs; the real model is never called in
`swift test`, per spec §7.

**Full-suite result recorded by the implementer:** 775/777, the same two `AdapterTests`
failures as this ledger's header, already present at base `d7eeb96` (verified in a scratch
worktree at the time) and confirmed again just now at `HEAD` — persistent on this machine
across the whole close-out, not a regression from Task 13's own commit.

### Task 14 — Close-out (this task)

This ledger, plus the gate run and spec walk recorded above and below. No code gap needed
a fix-first commit — see the spec walk's "not done" column, which is empty; every success
criterion and failure-table row already maps to a named test or screenshot from Tasks 1–13.

---

## Spec walk

Every row of spec §1 (success criteria) and §6 (failure table), with the test or
screenshot that shows it. No row was left without one.

### §1 Success criteria

| # | Criterion | Shown by |
|---|---|---|
| 1 | A clear photo of a typical Malaysian till receipt prefills the correct total and date. | `Tests/TaxCaptureTests/ReceiptParserTests.swift`, `corpus(name:)` over the 13-fixture corpus (supermarket, pharmacy, bookshop, clinic, bm-only, chinese-vendor, rounding, service-charge, …); `Tests/TaxCaptureTests/DocumentPipelineTests.swift`, `"a readable photo gives its fields, its text and its reliefs"`; `shots/scan.png` (Amount 71.90, Spent on 7 Mar 2025) |
| 2 | A MyInvois e-invoice's QR sets `eInvoiceUUID` and badges the document as an e-invoice, without changing which document kind it counts as. | `Tests/TaxCaptureTests/DocumentPipelineTests.swift`, `"a MyInvois QR sets the e-invoice ID"`; `Tests/TaxPresentationTests/ReceiptEditorTests.swift`, `"an e-invoice is badged and still attached as the kind the relief asks for"`. **Not shown on the simulator**: `shots/scan-einvoice.png`'s badge did not render there — see Task 12's section above; the underlying code path is proven by the macOS-run unit test |
| 3 | A number the on-device model returns that does not appear in the receipt's text never reaches the editor. | `Tests/TaxCaptureTests/ReceiptModelTests.swift`: `"a vendor that is not on the receipt is discarded"`, `"an out-of-range candidate is discarded"`, `"a relief it was not offered is discarded"` |
| 4 | A failed read at any stage leaves the user exactly where attaching leaves them today: a file attached and an editor to fill in by hand. | `Tests/TaxCaptureTests/DocumentPipelineTests.swift`, `"no text found: an empty reading, with the file still there to attach"`; `Tests/TaxPresentationTests/ReceiptEditorTests.swift`, `"what the receipt did not say stays blank, and a blank read is said so"` (asserts `model.couldNotReadReceipt && model.hasPendingReceipt`) |
| 5 | Attaching the same receipt or e-invoice to a second claim is warned about, not blocked. | `Tests/TaxDataTests/DocumentAttachmentTests.swift`, `"a file already on a claim is found by its hash, except on the entry asking"`, `"a different file of the same e-invoice is found by its ID"`; `Tests/TaxPresentationTests/ReceiptEditorTests.swift`, `"a receipt already on another claim is attached, with a warning"` (pins the exact copy, "This receipt already supports your RM 230.00 lifestyle claim from 3 Mar.") |

### §6 Failure table

| Failure | Spec's result | Shown by |
|---|---|---|
| Bytes cannot be decoded as an image or PDF | Existing "That photo/file could not be read" error; nothing written | `Tests/TaxCaptureTests/DocumentPipelineTests.swift`, `"bytes that cannot be decoded throw, and nothing else does"` |
| No text found | Empty prefill, file attached, footnote "Relio couldn't read this receipt — fill it in below." | `DocumentPipelineTests`, `"no text found: an empty reading, with the file still there to attach"`; `ReceiptEditorTests`, `"what the receipt did not say stays blank, and a blank read is said so"` (`couldNotReadReceipt`); copy itself lives at `App/TaxTracker/Entries/EntryEditorView.swift:324`, gated on that flag — not exercised in a screenshot (every scan screenshot is a successful read) |
| Text found, no total or date | The fields that were found; the others blank, not guessed | `ReceiptParserTests` corpus fixtures `no-total.json` (vendor only), `unlabelled-total.json` (total only, unconfirmed); `DocumentPipelineTests`, `"text with no total or date gives what it has and guesses nothing"` |
| QR present but not MyInvois | Ignored | `Tests/TaxCaptureTests/MyInvoisLinkTests.swift`, `"anything else is not a MyInvois link"`; `DocumentPipelineTests`, `"any other QR is ignored and reading carries on"` |
| Model unavailable or failing | Parser result, no message | `ReceiptModelTests`: `"a model that never answers is abandoned at the timeout"`, `"a model that throws gives no answer"`, `"a failing model leaves the parser's reading exactly as it was"` |
| File write fails | Existing "Relio could not save that file" error | `ReceiptEditorTests`, `"the file cannot be written: nothing is prefilled and the caller is told"` (scan-first) and `"the file cannot be written: nothing is attached"` (attach-to-existing) |

**Gaps found:** none requiring a fix. Every criterion and failure row has a named test or
screenshot; nothing needed a fix-first commit at close-out.

---

## Carried forward

Numbered on from the highest item number in the earlier ledgers (item 19, in
`docs/superpowers/logs/2026-08-25-income-timeline-execution-ledger.md`).

20. **Scan one real MyInvois e-invoice to confirm the host and `/{uuid}/share/{longId}`
    shape before release** (spec §2). Every test and screenshot here uses a synthetically
    generated QR; the parser's host/path assumptions have never been checked against a
    document LHDN actually issued.
21. **Whether LHDN accepts an e-invoice for every relief that requires an official receipt
    is a rulebook question.** Until it is answered, the document kind never becomes
    `.eInvoice` (spec §4) — a MyInvois receipt is recorded with `eInvoiceUUID` set but the
    same document kind attaching would have chosen otherwise, so it can still show as
    missing its receipt for a relief LHDN would in fact accept it for.
22. **The document camera has never run.** The simulator has none
    (`DocumentCameraView.isSupported` gates the option off it); every screenshot here used
    Photos/Files-equivalent input (`-relio-scan`'s generated sample). It needs a real
    device.
23. **The Foundation Models path runs only where Apple Intelligence is available.** On this
    simulator, `init?()` succeeded (`available: true`, confirmed in Task 13 with a
    temporary `print`), so the model object was constructed this run; that it was asked a question was not observed.
    **Whether an answer arrived within the 3 s timeout was not verified** — the sample
    receipt's single confident total and vendor give the fact-check nothing to change
    either way, and a model relief choice only reorders `suggestedReliefs` in the relief
    picker (never the Relief field), so no screenshot can distinguish "answered in time"
    from "timed out."
24. **Documents attached before this change are not re-read** (spec §8). Their `ocrText`,
    `eInvoiceUUID`, vendor, date and total stay exactly as they were before this plan —
    nothing here backfills them.
25. **The iCloud Drive file store and the share extension** (spec §8) remain separate,
    unstarted work; documents stay on one device.
26. **The e-invoice badge has never been seen on screen.** On the simulator, Vision's
    barcode request throws for the generated QR, so neither the pending badge nor the
    saved-document badge rendered. Both are driven by a tested `Bool`. Confirm them on a
    device, together with item 20.
27. **Parked Minors from the final review** (`final-review.md` numbering):
    - M4: the model is asked even when every field is already confirmed.
    - M5: model availability is checked once per launch.
    - M7: `ReadingStage.model` is never set, and `failures` has no reader in the UI.
    - M10: the 2000 px long edge may be too small for a QR on a tall receipt. Decide this
      after item 20's real scan.
    - M11: camera pages are JPEG-encoded on the main actor.
    - M12: relief keyword false positives ("POPULAR", "TUITION FEE", "INSURANCE").
    - M13: PDFTextReader re-creates the document per page, has no cancellation check,
      and uses a bare 0.8 quality.
    - M14: duplicated two-digit-year code, bare parser confidence literals, and an unused
      `record` binding.
    - The test fixture `SilentModel` leaks a continuation on purpose, and so prints a
      runtime warning on every `swift test` run, which could mask a real one.

---

## Final review

- **Reviewer:** opus, over `9476a18..f258790`.
- **Verdict:** With fixes. 0 Critical, 2 Important, 14 Minor.
- **I1:** text reading had no fallback. When the accurate mode failed, which it does on
  this Mac, the user waited 35–50 s behind the reading overlay and then got "couldn't
  read". The fast mode reads the same receipt in 0.14 s.
- **I2:** the MyInvois badge showed only before the entry was saved.

**One fix wave** (`0cf3852..a25e4fa`):
- I1: an 8 s bound on the accurate mode, then one retry in the fast mode, English only.
- I2: the badge on saved documents.
- M1 and M2: a failure on one page no longer loses the other pages' text and QR codes.
- M3: cancelling the caller also cancels the model race.
- M6: the README now describes what the model may change.
- M8: attaching a receipt to an existing entry says when nothing could be read.
- M9: a file left orphaned by e-invoice dedupe is deleted.
- The two AdapterTests that failed through this plan now pass, because the fast mode
  reads the receipt when the accurate one fails.

`68a98dd` also committed a debugging screenshot to the repo root by mistake. `c35a970`
removes it. History was not rewritten.

**The scoped re-review** found one new Critical in the shared race helper. A caller
already cancelled when the race starts runs the cancellation handler before the
operation, so the continuation attached afterwards was never resumed and the read hung
for good. The reviewer reproduced it 10 times out of 10. The controller fixed it
directly in `003a3bc`:
- The test "a caller cancelled before the race starts returns promptly" hung before the
  fix and passes after it.
- The race now keeps the winning value and resumes a late continuation with it.

## Verification gates

```bash
swift test 2>&1 | tail -5     # 789 tests in 96 suites, all passed
./Scripts/typecheck-app.sh    # Type-check succeeded (29 files)
swift build --target TaxCapture --triple arm64-apple-watchos26.0 --sdk "$(xcrun --sdk watchos --show-sdk-path)"   # complete
```
