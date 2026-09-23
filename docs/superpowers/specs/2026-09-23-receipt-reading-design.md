# Receipt reading — Design

**Parent:** `2026-08-23-malaysian-tax-relief-tracker-design.md`, §9 (document pipeline) and
§15 step 5. This spec finishes step 5 except for the iCloud Drive file store and the share
extension, which stay separate pieces of work.

**Status at start:** attaching a photo or file to a *saved* entry is built — a
content-addressed local `DocumentFileStore`, a ~30 KB thumbnail made in the view, and
`TaxStore.attach` re-deriving `needsDocument`. The attached `Document` records an empty
vendor and the entry's own date. `Document.ocrText`, `eInvoiceUUID`, `vendor`,
`documentDate` and `totalSen` have existed since Plan 2 and nothing has ever filled them.

---

## 1. Intent

A receipt should save the user typing, not just sit next to a claim.

- **Receipt starts the entry.** Scanning or picking a receipt opens a new-entry editor
  prefilled with amount, date and vendor, and with relief *candidates* — never a chosen
  relief. The receipt is attached when the entry is saved.
- **Attaching to an existing entry reads the receipt too**, fills the `Document`'s fields,
  and offers — never applies — the receipt's total when it disagrees with the entry.
- **The app never files a claim the user has not looked at** (parent §9). Nothing is
  saved until the user saves the editor; low-confidence fields are visibly unconfirmed.
- **Nothing leaves the device.** No network call anywhere in this pipeline.

### Success criteria

1. A clear photo of a typical Malaysian till receipt prefills the correct total and date.
2. A MyInvois e-invoice's QR sets `eInvoiceUUID` and badges the document as an e-invoice,
   without changing which document kind it counts as.
3. A number the on-device model returns that does not appear in the receipt's text never
   reaches the editor.
4. A failed read at any stage leaves the user exactly where attaching leaves them today:
   a file attached and an editor to fill in by hand.
5. Attaching the same receipt or e-invoice to a second claim is warned about, not blocked.

---

## 2. Decisions taken during design

| Decision | Chosen | Rejected, and why |
|---|---|---|
| Who produces numbers | A deterministic parser; the on-device model may only choose among its candidates or fill a blank, and every value it returns is checked against the OCR text | Model-first (parent §9 as written): untestable output, a hallucinated total reaches the editor, and the regex fallback rots because it rarely runs |
| MyInvois QR | Offline: parse the validation link for the document UUID only | Fetching the public validation page: a network call disclosing a document ID to LHDN, fragile HTML scraping, and contrary to parent §10's "no server, no network" |
| Resumable stages | Not resumable | Each stage is cheap and pure over its input and nothing is persisted mid-pipeline; resumability earns its cost only for background processing, which nothing here does |
| Low-confidence state | Editor state only, not persisted | Saving the entry *is* the user having looked, so a persisted `confirmed` flag would record nothing new — and it would force a `SchemaV2` (carried items 18 and 19) |
| Duplicate receipt on another claim | Warn | Block: one bill legitimately splits across two reliefs (books and a phone on one lifestyle receipt, say) |

**Why the MyInvois change from the parent spec.** Parent §9 expected the QR to give "a
government-verified vendor, date and total". It does not. The QR encodes the validation
link `{portal}/{uuid}/share/{longId}` and nothing else; the verified figures live behind
that link. Offline, the QR proves the document was submitted to MyInvois and gives the
strongest dedupe key available, which is still worth having. This resolves parent §14 open
item 2 as far as the offline design is concerned; a real e-invoice should still be scanned
once to confirm the host and path shape before release.

---

## 3. Architecture

A new target, `TaxCapture`, depending only on `TaxKit`. `TaxData` does not depend on it;
`TaxPresentation` and the app do.

```
TaxCapture
├── Parsing/            pure — no Vision, no FoundationModels, no SwiftUI
│   ├── OCRLine          text, page, vertical position, recogniser confidence
│   ├── RowAssembler     [TextFragment] -> [OCRLine]  (rejoins a row Vision split)
│   ├── ReceiptParser    [OCRLine] -> ReceiptFields
│   ├── MyInvoisLink     String -> MyInvoisLink?   (uuid, longId)
│   └── ReliefSuggester  (ReceiptFields, RuleSet) -> [ReliefCode] (≤ 3)
├── Reading/            adapters, each behind a protocol so tests can substitute
│   ├── TextReading      VisionTextReader (image), PDFTextReader (text layer first)
│   ├── BarcodeReading   VisionBarcodeReader
│   ├── ImageNormalising 2000 px long edge, JPEG, metadata stripped; thumbnail 320 px
│   └── ReceiptModel     FoundationModelsReceiptModel — optional, last unit
└── DocumentPipeline    actor: normalise → hash → thumbnail → barcode → text → extract
```

`DocumentPipeline.read(_ input: CaptureInput) async -> ReceiptReading`, where
`CaptureInput` is image data, PDF data, or scanned pages, and `ReceiptReading` carries:

- the normalised bytes, their SHA-256, byte count, UTI and thumbnail — everything
  `DocumentDraft` needs;
- `ocrText` (the joined lines) and `eInvoiceUUID`;
- `total`, `date`, `vendor`, each a `Reading<T>` of *value, confidence 0–1, source*
  (`.label("GRAND TOTAL")`, `.qr`, `.model`, `.heuristic`);
- `suggestedReliefs: [ReliefCode]`, in order;
- `failures`: which stages failed softly, so the UI can say "Relio couldn't read this
  receipt" rather than showing silent blanks.

The pipeline never throws for a read failure. It throws only when the input cannot be
decoded at all — the case that already has an error string today.

### Changes to existing code

- `DocumentDraft` gains `ocrText: String?` and `eInvoiceUUID: String?`; `TaxStore.attach`
  writes them. **No schema change**: `Document` already has both columns.
- `TaxStore` gains `claimsSupported(byHash:orEInvoiceUUID:excludingEntry:) ->
  [SupportedClaim]`, where `SupportedClaim` is `entryID`, `code`, `amount`, `spentOn` —
  what the duplicate warning prints, and nothing more.
- Thumbnail creation moves out of `EntryEditorView` into `ImageNormalising`.
- `EntryEditorViewModel` gains a prefill initialiser and a pending attachment (§5).

---

## 4. Reading a receipt

### Text

- **Image:** `VNRecognizeTextRequest`, `.accurate`, languages en-US, zh-Hans, zh-Hant,
  language correction off (Malay is Latin script; correction "fixes" it into English).
- **PDF:** the PDFKit text layer first — born-digital e-invoices have one and it is exact.
  Only a page with no text layer is rendered and OCR'd. Multi-page: all pages read, first
  page carries the most weight for vendor.

### Total

Candidates are amounts on a line carrying a label, or on the line immediately after a
label-only line. Ranked:

1. `GRAND TOTAL`, `JUMLAH BESAR`, `TOTAL AMOUNT PAYABLE`, `NET TOTAL`
2. `TOTAL`, `JUMLAH`, `AMOUNT DUE`, `AMAUN`
3. A rounding-adjusted figure (`ROUNDING` / `PELARASAN` present): the adjusted total beats
   the unrounded one.

Excluded outright: `SUBTOTAL`, `SUB-TOTAL`, `TAX`, `SST`, `SERVICE CHARGE`, `DISCOUNT`,
`CHANGE`, `BAKI`, `CASH`, `TUNAI`, `TENDERED`, `CARD`, `SAVINGS`. Amounts are scanned by
`TaxCapture`'s own `ReceiptAmount` into `Money(sen:)` — not `MoneyParsing`, which lives in
`TaxPresentation` and parses what a user types, not what a till prints (`RM12.50`,
`12.50-`, `12.50 RM`). Exactly two decimals are required; anything else is not a
candidate.

Confidence falls when two top-rank candidates disagree, when the only candidate is
unlabelled (the largest amount on the receipt, as a last resort, capped at 0.5), or when
the recogniser's own confidence on the line is low.

### Date

Day-first, interpreted in `Asia/Kuala_Lumpur`, stored the way entry dates already are.
Formats: `dd/mm/yyyy`, `dd/mm/yy`, `dd-mm-yyyy`, `dd.mm.yyyy`, `dd MMM yyyy`,
`dd-MMM-yy`, ISO `yyyy-mm-dd`. Month names in English and Malay (`Jan`, `Mac`, `Mei`,
`Ogos`, `Okt`, `Dis`). A date in the future or more than seven years back is not a
candidate. When day and month are both ≤ 12 the day-first reading is kept at reduced
confidence. A date labelled `DATE`/`TARIKH`/`INVOICE DATE` beats an unlabelled one; an
expiry, due or print date is excluded.

### Vendor

The first line in the top third of the first page that is mostly letters, is not a
document title (`TAX INVOICE`, `RESIT`, `RECEIPT`, `INVOIS`, `CASH BILL`), and is not an
address or phone line. A line containing `SDN BHD`, `SDN. BHD.`, `BERHAD`, `ENTERPRISE`,
`PLT`, `TRADING` wins over one that does not. The registration number in brackets is
stripped. Low confidence by default (0.6) unless a company suffix matched.

### Relief suggestion

`ReliefSuggester` maps whole-word vendor and line keywords straight to relief codes, then
keeps only codes present and user-claimable (not automatic) in **that year's rulebook**.
Examples: `KLINIK`, `CLINIC`, `HOSPITAL` → serious medical and check-up; `DENTAL`,
`PERGIGIAN` → dental; `BUKU`, `BOOKSTORE`, `MPH` → lifestyle; `GYM`, `FITNESS`,
`DECATHLON` → sports; `TADIKA`, `TASKA`, `NURSERY` → childcare. At most three codes,
never auto-selected. No match means no suggestions, not a guess.

Straight to codes rather than through `ReliefCategory`: that type lives in
`TaxPresentation`, and a family is too coarse — "Health" holds eight reliefs, and a
dental receipt belongs to one of them. The table is data in `TaxCapture`, tested row by
row against every shipped rulebook.

### MyInvois QR

`VNDetectBarcodesRequest` limited to QR. A payload is accepted only when it parses as an
HTTPS URL on `myinvois.hasil.gov.my` or `preprod.myinvois.hasil.gov.my` with exactly the
path `/{uuid}/share/{longId}`, no query and no fragment. MyInvois document IDs are **not**
RFC 4122 UUIDs — LHDN's own API example is `F9D425P6DS7D8IU` — so `uuid` must be 10–40
ASCII letters and digits, and `longId` at least 10. Accepted: `eInvoiceUUID` is set and the
editor shows a "MyInvois e-invoice" badge. Anything else is ignored and reading continues.

**The document kind does not become `.eInvoice`.** `TaxStore` decides a claim is supported
when `requiredDocuments ⊆ documentKinds`, and twelve YA2025 reliefs require
`officialReceipt`. Recording a MyInvois receipt as `.eInvoice` would leave the claim
flagged as missing its receipt. The kind is chosen as attaching chooses it today — the
selected relief's first required kind, else `officialReceipt` — and the e-invoice status
lives in `eInvoiceUUID`. Whether LHDN treats an e-invoice as satisfying every requirement
is a rulebook question, out of scope here.

### The on-device model (last unit)

Where `SystemLanguageModel.default.availability == .available`:

```swift
@Generable struct ReceiptModelAnswer {
    @Guide("Merchant name as printed")             var vendor: String?
    @Guide("Index of the grand total among the candidates given, or null")
                                                   var totalCandidate: Int?
    @Guide("Best-matching relief among the codes given, or null")
                                                   var relief: String?
}
```

The prompt carries the OCR text, the parser's total candidates as an indexed list, and
the year's claimable relief codes with their names. The model:

- **may** choose among total candidates when the parser's top two disagree;
- **may** supply a vendor when the parser found none, or found one below 0.6;
- **may** move a relief it names to the front of the suggestions, if the code is in the
  list it was given.

**Fact-check.** A vendor must appear in the OCR text (case-insensitive, whitespace
collapsed). A candidate index must be in range. A relief must be one of the codes given.
Anything failing a check is discarded silently. The model's contribution is never above
0.7 confidence, so it is always shown as unconfirmed. Model unavailable, refusing, timing
out (3 s) or erroring: the parser's result stands, with no message.

---

## 5. Flows

### Scan first

1. "Scan a receipt" sits beside "Add entry" on Home and the entries list. It offers the
   document camera (`VNDocumentCameraViewController`, iPhone and iPad), Photos, or Files.
2. The pipeline runs behind a short progress state in the sheet.
3. `EntryEditorViewModel(prefill: ReceiptReading, …)` opens as a new entry: amount, date
   and vendor set; relief left unselected with the candidates shown first in the picker;
   each field below 0.7 marked unconfirmed until the user edits it or taps to confirm.
4. The file waits as a **pending attachment** — already written to `DocumentFileStore`,
   not yet a `Document`.
5. **Save** saves the entry, then attaches the pending draft through `TaxStore.attach`.
   **Cancel** deletes the file if no live `DocumentFile` references its hash.

If the attach step fails after the entry saved, the entry stays and the editor reports it
with the existing "Relio could not attach that" copy; the file stays on disk so a retry
does not rescan.

### Attaching to an existing entry

The existing Photos and Files buttons, plus the document camera, run the same pipeline.
The `Document` is recorded with the read vendor, date, total, OCR text and e-invoice
UUID. If the read total is confident (≥ 0.7) and differs from the entry's amount, the
documents section shows "The receipt says RM 128.40. Use that?" — one tap sets the
amount field, which the user still saves. Offer, never inject.

### Duplicate warning

Before attaching — in either flow — the store is asked whether this `contentHash` or
`eInvoiceUUID` already supports another live entry. If so: "This receipt already supports
your RM 230.00 lifestyle claim from 3 Mar." The user can attach anyway.

---

## 6. Failure handling

| Failure | Result |
|---|---|
| Bytes cannot be decoded as an image or PDF | The existing "That photo could not be read" error; nothing written |
| No text found | Empty prefill, file attached, footnote "Relio couldn't read this receipt — fill it in below" |
| Text found, no total or date | The fields that were found; the others blank, not guessed |
| QR present but not MyInvois | Ignored |
| Model unavailable or failing | Parser result, no message |
| File write fails | The existing "Relio could not save that file" error |

**Normalising.** Images are resized to a 2000 px long edge and re-encoded as JPEG with all
metadata stripped — a receipt photo carries GPS in its EXIF, and the store should not.
The hash is of the normalised bytes (parent §9 stage 2). PDFs are stored unchanged;
their thumbnail is page one rendered at 320 px.

---

## 7. Testing and verification

- **Parser:** a fixture corpus of `[OCRLine]` JSON — supermarket, pharmacy, bookshop,
  clinic, BM-only, Chinese-script vendor, rounding adjustment, service charge, no total,
  two conflicting totals, ambiguous day/month, future date. Each fixture pins the expected
  total, date, vendor and confidence band.
- **MyInvois:** valid production and preprod links; wrong host, `http`, extra path
  segments, an ID with punctuation, trailing query — all rejected.
- **Suggester:** keyword table rows; a code absent from the year's rulebook is never
  returned; automatic codes never returned.
- **Adapters:** run for real in `swift test` on macOS — receipts rendered with CoreGraphics
  into PNG and PDF, a QR generated with CoreImage. Asserts the adapters return the text
  and payload, not exact OCR output.
- **Model fact-check:** a stub `ReceiptModel` returning an out-of-text vendor, an
  out-of-range index and an unknown code — all discarded. The real model is not called in
  tests.
- **Pipeline:** stub adapters driving each row of §6.
- **View model:** prefill, unconfirmed state clearing on edit, attach-on-save,
  cleanup-on-cancel, the amount offer, the duplicate warning.
- **App:** a DEBUG `-relio-scan` launch argument feeds a generated receipt through the real
  pipeline into the prefilled editor, screenshotted at default size and AX5, edges
  checked. The document camera and system pickers themselves remain untapped, as today.
- **Manual:** README's "Current state" table and running notes updated in the same change.

---

## 8. Out of scope

- The iCloud Drive file store and `DocumentFile.DownloadState` (parent §6).
- The share extension, Mac drag and drop, and the Watch `needsDocument` inbox.
- Fetching the MyInvois validation page.
- Line-item splitting of one receipt across several reliefs.
- Re-reading documents attached before this change. Their fields stay as they are.
