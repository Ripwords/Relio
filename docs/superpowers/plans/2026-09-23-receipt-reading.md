# Receipt Reading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A receipt — scanned, picked from Photos or opened from Files — is read on device and prefills a new entry (amount, date, vendor, relief candidates) or fills the `Document` it is attached to, with every uncertain field visibly unconfirmed and nothing saved until the user saves.

**Architecture:** A new `TaxCapture` target (depends on `TaxKit` only) holds a pure, fixture-tested parser (`Parsing/`), thin platform adapters behind protocols (`Reading/`: Vision text and QR, PDFKit, ImageIO normaliser, Foundation Models), and a `DocumentPipeline` actor that runs them and never throws for a read failure. `TaxData` gains two `DocumentDraft` fields and two queries (no schema change). `EntryEditorViewModel` gains a scan-first prefill with a pending attachment, and the app wires a document camera and a "Scan a receipt" button to it.

**Tech Stack:** Swift 6.2 (language mode 6), Swift Testing, SwiftData, Vision (`RecognizeTextRequest`, `DetectBarcodesRequest`), PDFKit, ImageIO, CoreText/CoreImage (test fixtures only), FoundationModels, VisionKit (app only), SwiftUI. Xcode 26, iOS/macOS 26.

**Spec:** `docs/superpowers/specs/2026-09-23-receipt-reading-design.md` (read it alongside this plan; section numbers below — §4, §5, §6 — are the spec's).

## Global Constraints

- New target `TaxCapture` depends on `["TaxKit"]` only. `TaxData` must **not** depend on `TaxCapture`; `TaxPresentation` and the app do.
- Every target uses `swiftSettings: [.swiftLanguageMode(.v6)]`. Platforms stay `.iOS(.v26), .macOS(.v26), .watchOS(.v26)`.
- `TaxCapture/Parsing/` imports `Foundation` and `TaxKit` only — no Vision, PDFKit, ImageIO, FoundationModels or SwiftUI.
- Platform code is guarded: `#if canImport(Vision)`, `#if canImport(PDFKit)`, `#if canImport(FoundationModels)`. The package must still build for watchOS.
- **No network call anywhere in this pipeline.** No `URLSession`, no fetching the MyInvois page.
- **Offer, never inject.** Nothing is persisted until the user taps Save. A receipt total that disagrees with an entry is offered, never applied.
- A reading below `ReadingConfidence.confirmed` (**0.7**) is shown unconfirmed. Model contributions carry **0.65**, so they are always unconfirmed.
- The document kind is `requiredDocumentKinds.first ?? .officialReceipt`. A MyInvois QR sets `eInvoiceUUID`; it **never** changes the kind to `.eInvoice`.
- Dates are interpreted day-first in `Asia/Kuala_Lumpur` and stored at **noon KL**, the way entry dates already are.
- Amounts are `Money(sen:)` — never `Double`. `TaxCapture` does not use `MoneyParsing` (it lives in `TaxPresentation` and parses typed input).
- Images are normalised to a **2000 px** long edge, re-encoded JPEG, all metadata stripped. Thumbnails are **320 px** long edge, JPEG quality **0.6**, and must stay under **30 KB**. PDFs are stored unchanged.
- The content hash is the one `DocumentFileStore.write` returns (SHA-256 of the normalised bytes). `ReceiptReading` carries no hash of its own — see "Deviation from the spec" below.
- Existing copy is kept verbatim: "That photo could not be read. Try another.", "That file could not be read. Try another.", "That file could not be opened. Try another.", "Relio could not attach that. Nothing was lost — try again.", "Relio could not save that file. Try again."
- New copy, verbatim: "Relio couldn't read this receipt — fill it in below.", "MyInvois e-invoice", "The receipt says RM 128.40. Use that?" (figure varies), "This receipt already supports your RM 230.00 lifestyle claim from 3 Mar." (figures vary), "This receipt is dated 2024. It will count towards YA 2025 — switch year first if that is wrong." (years vary).
- New copy for the app (Task 12), verbatim: "Scan a receipt", "Scan with the camera", "Choose a photo", "Choose a file", "Reading the receipt…", "Receipt", "Attached when you save.", "Relio was not sure of the marked fields. Check them, or tap the mark to confirm.", "Read from the receipt, not confirmed" (accessibility), "Suggested from the receipt", "All reliefs", "Use it", "Keep mine", "The camera stopped before the scan finished. Try again.", and the camera permission "Relio uses the camera to scan receipts. The photo stays on this device."
- Test clock epoch: `Date(timeIntervalSince1970: 1_750_000_000)` = 15 June 2025.
- Git: Conventional Commits; stage **explicit paths only** (never `git add -A`); never pass `-c user.email`/`-c user.name`; every commit message ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Do not push.
- TDD: every task writes its failing test first and runs it before implementing.
- There is no CI. `swift test` and `./Scripts/typecheck-app.sh` are the gates.

### Deviations from the spec (decided while planning)

1. **No `contentHash` in `ReceiptReading`.** The spec lists "their SHA-256". The hash is taken from `DocumentFileStore.write` instead, so there is one SHA-256 implementation rather than two that must agree. The pipeline's "hash" stage is therefore the file write the caller does.
2. **Prefill is a method, not an initialiser.** `EntryEditorViewModel.prefill(from:files:) -> Bool` is called before `load()`, because writing the pending file can fail and an initialiser cannot report that cleanly.
3. **Model vendor threshold is 0.7, not 0.6.** The parser's default vendor confidence *is* 0.6, so "below 0.6" would never let the model help. The model may replace a vendor read below 0.7.
4. **Model confidence is 0.65**, strictly below 0.7, which makes "never above 0.7" and "always unconfirmed" the same statement.
5. **Unlabelled total fallback is 0.4** (spec: "capped at 0.5") — inside the cap.

## Review Focus

1. **A sideways photo.** An iPhone photo stored landscape with EXIF orientation 6 must be stored upright after normalising (metadata is stripped, so the rotation must be applied, not dropped). Test: Task 6, `orientationIsApplied`.
2. **Cancelling a scan must not delete a file another claim uses.** The same receipt already attached to a saved entry, scanned again and cancelled, must leave the file on disk. Test: Task 10, `cancelKeepsAFileAnotherClaimUses`.
3. **A receipt dated outside the open Year of Assessment.** A December 2024 receipt scanned while YA 2025 is open is saved into YA 2025 — the editor has no year field. The VM exposes `receiptYearMismatch` and the editor says "This receipt is dated 2024. It will count towards YA 2025 — switch year first if that is wrong." Test: Task 10, `receiptFromAnotherYearIsFlagged`.
4. **A removed receipt must not trigger the duplicate warning.** A document soft-deleted from one claim (or attached to a deleted entry) no longer supports anything. Test: Task 9, `removedDocumentsSupportNothing`.
5. **A long scanned PDF.** An image-only 40-page PDF must not OCR all 40 pages; at most the first 5 are rendered. Test: Task 7, `ocrFallbackStopsAtFivePages`.

---

## File Structure

```
Sources/TaxCapture/
├── Parsing/
│   ├── Reading.swift            Reading<Value>, ReadingSource, ReadingConfidence
│   ├── OCRLine.swift            OCRLine
│   ├── ReceiptAmount.swift      amounts printed on a till line -> [Money]
│   ├── ReceiptDate.swift        dates on a line -> [DateCandidate]
│   ├── Phrase.swift             upper-case whole-word matching for labels and keywords
│   ├── RowAssembler.swift       TextFragment, [TextFragment] -> [OCRLine]
│   ├── ReceiptParser.swift      [OCRLine] -> ReceiptFields
│   ├── MyInvoisLink.swift       QR payload -> (uuid, longId)?
│   └── ReliefSuggester.swift    keyword table -> [ReliefCode]
├── Reading/
│   ├── CaptureInput.swift       CaptureInput, CaptureError, NormalisedDocument
│   ├── ImageCoding.swift        ImageIO helpers shared by normaliser + sample receipt
│   ├── PDFPageRenderer.swift    render a PDF page to CGImage / JPEG
│   ├── ImageNormaliser.swift    ImageNormalising + ImageNormaliser
│   ├── TextReading.swift        TextReading, PDFTextReading, BarcodeReading protocols
│   ├── VisionTextReader.swift   Vision OCR adapter
│   ├── VisionBarcodeReader.swift Vision QR adapter
│   ├── PDFTextReader.swift      text layer first, OCR fallback ≤ 5 pages
│   ├── ReceiptModel.swift       ReceiptModel protocol, question/answer, fact-check
│   ├── FoundationModelsReceiptModel.swift
│   └── SampleReceipt.swift      DEBUG: renders a receipt PNG/JPEG/PDF (+ QR)
└── DocumentPipeline.swift       actor, ReceiptReading

Tests/TaxCaptureTests/
├── Fixtures/receipts/*.json     13 OCR-line fixtures
├── ReceiptAmountTests.swift  ReceiptDateTests.swift  RowAssemblerTests.swift
├── ReceiptParserTests.swift  MyInvoisLinkTests.swift ReliefSuggesterTests.swift
├── ImageNormaliserTests.swift AdapterTests.swift DocumentPipelineTests.swift
└── ReceiptModelTests.swift

Sources/TaxData/Store/TaxStore+Documents.swift      + ocrText, eInvoiceUUID, claimsSupported, isFileReferenced
Tests/TaxDataTests/DocumentAttachmentTests.swift     + tests
Sources/TaxPresentation/EntryEditorViewModel.swift   (edit: stable newEntryID, duplicate check)
Sources/TaxPresentation/EntryEditorViewModel+Receipt.swift   new: scan-first + attach reading
Tests/TaxPresentationTests/ReceiptEditorTests.swift  new
Tests/TaxPresentationTests/EntryEditorViewModelTests.swift   migrate attachDocument calls
App/TaxTracker/Capture/CapturePipeline.swift         new
App/TaxTracker/Capture/DocumentCameraView.swift      new
App/TaxTracker/Capture/ReceiptCaptureModifier.swift  new
App/TaxTracker/Entries/EntryEditorView.swift         edit
App/TaxTracker/Entries/ReliefPickerView.swift        edit: "Suggested from the receipt" section
App/TaxTracker/RootView.swift                        edit
App/TaxTracker/Support/DemoHarness.swift             edit
App/TaxTracker/Info.plist, Package.swift, project.yml, Scripts/run-app.sh, README.md
docs/superpowers/logs/2026-09-23-receipt-reading-execution-ledger.md   new (Task 14)
```

---

### Task 1: `TaxCapture` scaffold, readings, and amounts on a till line

**Files:**
- Modify: `Package.swift` (products; new targets; `TaxPresentation` dependencies)
- Modify: `project.yml:36-42` (app dependencies)
- Modify: `Scripts/run-app.sh:53-54` (link `TaxCapture` objects)
- Create: `Sources/TaxCapture/Parsing/Reading.swift`
- Create: `Sources/TaxCapture/Parsing/OCRLine.swift`
- Create: `Sources/TaxCapture/Parsing/ReceiptAmount.swift`
- Test: `Tests/TaxCaptureTests/ReceiptAmountTests.swift`

**Interfaces:**
- Consumes: `TaxKit.Money` (`init(sen:)`, `Comparable`, `+`, `-`, `.zero`).
- Produces:
  - `public enum ReadingSource: Hashable, Sendable { case label(String), qr, model, heuristic }`
  - `public struct Reading<Value: Hashable & Sendable>: Hashable, Sendable { value: Value; confidence: Double; source: ReadingSource; var isConfirmed: Bool }`
  - `public enum ReadingConfidence { static let confirmed: Double = 0.7; static let model: Double = 0.65 }`
  - `public struct OCRLine: Hashable, Sendable, Codable { text: String; page: Int; top: Double; confidence: Double }` — `top` is 0 at the top of the page, 1 at the bottom.
  - `public enum ReceiptAmount { static func amounts(in line: String) -> [Money] }`

- [ ] **Step 1: Add the target to the package**

In `Package.swift`, add the product after `TaxPresentation`'s:

```swift
        .library(name: "TaxCapture", targets: ["TaxCapture"]),
```

Add these two targets at the end of `targets:`:

```swift
        // Reads a receipt: OCR, the MyInvois QR, and a deterministic parser over the
        // result. Depends on TaxKit only — TaxData must never need it.
        .target(
            name: "TaxCapture",
            dependencies: ["TaxKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TaxCaptureTests",
            dependencies: ["TaxCapture"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
```

Change `TaxPresentation`'s dependencies to `["TaxKit", "TaxData", "TaxCapture"]`.

In `project.yml`, after the `TaxPresentation` dependency, add:

```yaml
      - package: TaxKit
        product: TaxCapture
```

In `Scripts/run-app.sh`, replace lines 53–54 with:

```bash
mapfile -t OBJS < <(find .build-ios/debug/TaxKit.build .build-ios/debug/TaxData.build \
                         .build-ios/debug/TaxPresentation.build \
                         .build-ios/debug/TaxCapture.build -name '*.o' | sort)
```

- [ ] **Step 2: Write the reading types**

`Sources/TaxCapture/Parsing/Reading.swift`:

```swift
import Foundation

/// Where a value read off a receipt came from. Shown to nobody; kept so a test, and a
/// person debugging a bad read, can tell a labelled total from a guess.
public enum ReadingSource: Hashable, Sendable {
    /// Found next to a printed label, e.g. `.label("GRAND TOTAL")`.
    case label(String)
    /// From the MyInvois QR code.
    case qr
    /// Chosen by the on-device language model, and fact-checked against the text.
    case model
    /// A last resort with no label — the largest amount on the receipt, say.
    case heuristic
}

/// A value read off a receipt, with how sure the reader is of it.
public struct Reading<Value: Hashable & Sendable>: Hashable, Sendable {
    public var value: Value
    /// 0 to 1. Below `ReadingConfidence.confirmed` the editor shows it unconfirmed.
    public var confidence: Double
    public var source: ReadingSource

    public init(value: Value, confidence: Double, source: ReadingSource) {
        self.value = value
        self.confidence = confidence
        self.source = source
    }

    public var isConfirmed: Bool { confidence >= ReadingConfidence.confirmed }
}

public enum ReadingConfidence {
    /// At or above this, a field is prefilled as if the user had typed it.
    public static let confirmed: Double = 0.7
    /// Everything the language model contributes. Strictly below `confirmed`, so a
    /// model's answer is always shown for the user to check.
    public static let model: Double = 0.65
}
```

`Sources/TaxCapture/Parsing/OCRLine.swift`:

```swift
import Foundation

/// One printed row of a receipt, as the recogniser read it.
public struct OCRLine: Hashable, Sendable, Codable {
    public var text: String
    /// Zero-based page. Only page 0 is searched for the vendor.
    public var page: Int
    /// Distance from the top of the page, 0 to 1. Vision reports a bottom-left origin;
    /// the adapter flips it so "top third" reads as `top < 1/3`.
    public var top: Double
    /// The recogniser's own confidence, 0 to 1. The lowest fragment's, for a row that
    /// was assembled from several.
    public var confidence: Double

    public init(text: String, page: Int = 0, top: Double = 0, confidence: Double = 1) {
        self.text = text
        self.page = page
        self.top = top
        self.confidence = confidence
    }
}
```

- [ ] **Step 3: Write the failing amount tests**

`Tests/TaxCaptureTests/ReceiptAmountTests.swift`:

```swift
import Testing
import TaxKit
@testable import TaxCapture

/// A till prints money in more shapes than a person types it — `RM12.50`, `12.50 RM`,
/// `5.00-` for a discount — and prints plenty of numbers that are not money at all.
@Suite("Amounts on a till line") struct ReceiptAmountTests {

    @Test("the shapes a till prints", arguments: [
        ("TOTAL RM12.50", 1_250),
        ("TOTAL 12.50 RM", 1_250),
        ("GRAND TOTAL 1,234.56", 123_456),
        ("JUMLAH RM 7.00", 700),
        ("TOTAL: 0.90", 90),
    ])
    func readsTillShapes(line: String, sen: Int) {
        #expect(ReceiptAmount.amounts(in: line) == [Money(sen: sen)])
    }

    @Test("numbers that are not money", arguments: [
        "QTY 12.5",            // one decimal place
        "WEIGHT 12.500 KG",    // three
        "12.03.2025",          // a date
        "SST 6.00%",           // a rate
        "INV 2025/0001",
        "TEL 03-2345 6789",
        "",
    ])
    func ignoresNonMoney(line: String) {
        #expect(ReceiptAmount.amounts(in: line).isEmpty)
    }

    @Test("a discount printed with a trailing or leading minus is negative")
    func readsNegatives() {
        #expect(ReceiptAmount.amounts(in: "DISC 5.00-") == [Money(sen: -500)])
        #expect(ReceiptAmount.amounts(in: "DISCOUNT -RM 5.00") == [Money(sen: -500)])
        #expect(ReceiptAmount.amounts(in: "DISCOUNT -5.00") == [Money(sen: -500)])
    }

    /// A dash used as a separator is not a sign. "BOOK - 12.00" is a line item.
    @Test("a spaced dash is a separator, not a minus")
    func spacedDashIsNotASign() {
        #expect(ReceiptAmount.amounts(in: "BOOK - 12.00") == [Money(sen: 1_200)])
    }

    @Test("every amount on the line, in order")
    func readsSeveral() {
        #expect(ReceiptAmount.amounts(in: "2 x 3.50 7.00") == [Money(sen: 350), Money(sen: 700)])
    }

    /// `Money(sen:)` would take it, but multiplying a 20-digit ringgit figure by 100
    /// overflows `Int` and traps. A misread barcode must not crash the reader.
    @Test("an absurdly long number is skipped rather than crashing")
    func overflowIsSkipped() {
        #expect(ReceiptAmount.amounts(in: "12345678901234567890.00").isEmpty)
    }
}
```

- [ ] **Step 4: Run it to see it fail**

Run: `swift test --filter ReceiptAmountTests`
Expected: FAIL — `cannot find 'ReceiptAmount' in scope`.

- [ ] **Step 5: Implement `ReceiptAmount`**

`Sources/TaxCapture/Parsing/ReceiptAmount.swift`:

```swift
import Foundation
import TaxKit

/// Money as a till prints it.
///
/// Not `MoneyParsing`, which lives in `TaxPresentation` and reads what a person types.
/// A till prints `RM12.50`, `12.50 RM` and `5.00-`, and prints dates, rates and weights
/// that look like amounts. Exactly two decimals are required: `12.5` and `12.500` are a
/// quantity and a weight far more often than they are money.
public enum ReceiptAmount {

    public static func amounts(in line: String) -> [Money] {
        // Swift's Regex has no lookbehind, so "not preceded by a digit, `.` or `,`" is
        // checked by hand below. The lookahead refuses a third decimal, a following
        // `.5`/`,5` (a date or a longer number) and a percentage.
        let pattern = /(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})(?!\d|[.,]\d|%)/
        var result: [Money] = []
        for match in line.matches(of: pattern) {
            let range = match.range
            if range.lowerBound > line.startIndex {
                let before = line[line.index(before: range.lowerBound)]
                if before.isNumber || before == "." || before == "," { continue }
            }
            // `Int(_:)` refuses non-ASCII digits, which `\d` admits. Refusing is right.
            guard let ringgit = Int(match.output.1.replacingOccurrences(of: ",", with: "")),
                  let sen = Int(match.output.2) else { continue }
            let (hundreds, overflowed) = ringgit.multipliedReportingOverflow(by: 100)
            guard !overflowed else { continue }
            let (total, overflowedAgain) = hundreds.addingReportingOverflow(sen)
            guard !overflowedAgain else { continue }
            result.append(Money(sen: isNegative(range, in: line) ? -total : total))
        }
        return result
    }

    /// `-5.00`, `-RM5.00`, `-RM 5.00` and `5.00-` are negative. `BOOK - 12.00` is not:
    /// the dash must touch the number or its `RM`.
    private static func isNegative(_ range: Range<String.Index>, in line: String) -> Bool {
        if line[range.upperBound...].first == "-" { return true }
        var head = line[..<range.lowerBound]
        let trimmed = head.reversed().drop(while: { $0 == " " })
        let trimmedHead = String(trimmed.reversed())
        if trimmedHead.uppercased().hasSuffix("RM") {
            head = Substring(trimmedHead.dropLast(2))
        }
        return head.last == "-"
    }
}
```

- [ ] **Step 6: Run the tests to see them pass**

Run: `swift test --filter ReceiptAmountTests`
Expected: PASS, all cases.

Then run the whole suite once to prove the package change broke nothing: `swift test`
Expected: PASS (every existing suite plus this one).

- [ ] **Step 7: Commit**

```bash
git add Package.swift project.yml Scripts/run-app.sh \
  Sources/TaxCapture/Parsing/Reading.swift Sources/TaxCapture/Parsing/OCRLine.swift \
  Sources/TaxCapture/Parsing/ReceiptAmount.swift Tests/TaxCaptureTests/ReceiptAmountTests.swift
git commit -m "feat(capture): add the TaxCapture target and read amounts off a till line

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Dates on a receipt line

**Files:**
- Create: `Sources/TaxCapture/Parsing/ReceiptDate.swift`
- Test: `Tests/TaxCaptureTests/ReceiptDateTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public struct DateCandidate: Hashable, Sendable { date: Date; ambiguous: Bool }` — `date` is noon in Asia/Kuala_Lumpur.
  - `public enum ReceiptDate { static let timeZone: TimeZone; static func dates(in line: String, now: Date) -> [DateCandidate]; static func noon(_ y: Int, _ m: Int, _ d: Int) -> Date? }`

- [ ] **Step 1: Write the failing tests**

`Tests/TaxCaptureTests/ReceiptDateTests.swift`:

```swift
import Testing
import Foundation
@testable import TaxCapture

@Suite("Dates on a receipt line") struct ReceiptDateTests {

    /// 15 June 2025, the suite-wide test clock.
    static let now = Date(timeIntervalSince1970: 1_750_000_000)

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { ReceiptDate.noon(y, m, d)! }

    @Test("the formats Malaysian tills print", arguments: [
        ("DATE: 14/03/2025", 2025, 3, 14),
        ("14/03/25 13:02", 2025, 3, 14),
        ("14-03-2025", 2025, 3, 14),
        ("14.03.2025", 2025, 3, 14),
        ("2025-03-14", 2025, 3, 14),
        ("2025/03/14", 2025, 3, 14),
        ("14 Mar 2025", 2025, 3, 14),
        ("07 Mac 2025", 2025, 3, 7),
        ("28-OGOS-2024", 2024, 8, 28),
        ("3 Mei 2025", 2025, 5, 3),
        ("1-Okt-24", 2024, 10, 1),
        ("25 Dis 2024", 2024, 12, 25),
        ("5 June, 2025", 2025, 6, 5),
    ])
    func readsFormats(line: String, y: Int, m: Int, d: Int) {
        let found = ReceiptDate.dates(in: line, now: Self.now)
        #expect(found.map(\.date) == [Self.day(y, m, d)])
    }

    @Test("an impossible date is not a date")
    func rejectsImpossible() {
        #expect(ReceiptDate.dates(in: "31/02/2025", now: Self.now).isEmpty)
        #expect(ReceiptDate.dates(in: "00/03/2025", now: Self.now).isEmpty)
    }

    @Test("a date in the future is not a candidate")
    func rejectsFuture() {
        #expect(ReceiptDate.dates(in: "20/07/2025", now: Self.now).isEmpty)
    }

    @Test("today is a candidate")
    func acceptsToday() {
        #expect(ReceiptDate.dates(in: "15/06/2025", now: Self.now).map(\.date)
                == [Self.day(2025, 6, 15)])
    }

    @Test("more than seven years back is not a candidate")
    func rejectsAncient() {
        #expect(ReceiptDate.dates(in: "14/03/2017", now: Self.now).isEmpty)
        #expect(ReceiptDate.dates(in: "16/06/2018", now: Self.now).count == 1)
    }

    @Test("day and month both twelve or under, and different, is ambiguous")
    func flagsAmbiguous() {
        #expect(ReceiptDate.dates(in: "04/05/2025", now: Self.now).first?.ambiguous == true)
        #expect(ReceiptDate.dates(in: "05/05/2025", now: Self.now).first?.ambiguous == false)
        #expect(ReceiptDate.dates(in: "14/03/2025", now: Self.now).first?.ambiguous == false)
        #expect(ReceiptDate.dates(in: "14 Mar 2025", now: Self.now).first?.ambiguous == false)
    }

    @Test("numbers that are not dates", arguments: [
        "TEL 03-2345 6789",
        "INV 2025/0001",
        "TOTAL 12.50",
        "SST ID W10-1808-32000123",
    ])
    func ignoresNonDates(line: String) {
        #expect(ReceiptDate.dates(in: line, now: Self.now).isEmpty)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter ReceiptDateTests`
Expected: FAIL — `cannot find 'ReceiptDate' in scope`.

- [ ] **Step 3: Implement**

`Sources/TaxCapture/Parsing/ReceiptDate.swift`:

```swift
import Foundation

public struct DateCandidate: Hashable, Sendable {
    /// Noon in Asia/Kuala_Lumpur, the way entry dates are stored.
    public var date: Date
    /// Day and month are both 12 or under and differ, so `04/05` could be either. Read
    /// day-first — Malaysia's convention — at reduced confidence.
    public var ambiguous: Bool
}

/// Dates as Malaysian receipts print them, read day-first.
public enum ReceiptDate {

    public static let timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// English and Malay month names, by their first three letters. `mac`, `mei`, `ogo`,
    /// `okt` and `dis` are the Malay ones that differ from English.
    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "mac": 3, "apr": 4, "may": 5, "mei": 5,
        "jun": 6, "jul": 7, "aug": 8, "ogo": 8, "sep": 9, "oct": 10, "okt": 10,
        "nov": 11, "dec": 12, "dis": 12,
    ]

    public static func noon(_ year: Int, _ month: Int, _ day: Int) -> Date? {
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = day; parts.hour = 12
        guard let date = calendar.date(from: parts) else { return nil }
        // `Calendar` rolls 31 February over into March. Reading it back is what refuses it.
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    public static func dates(in line: String, now: Date) -> [DateCandidate] {
        var found: [(Int, Int, Int, Bool)] = []   // year, month, day, ambiguous

        // Swift's Regex has no lookbehind, so "no digit immediately before" is checked
        // by hand (`startsCleanly`). With the lookaheads, that stops a phone number or an
        // ID containing digit runs being read as a date.
        let iso = /(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})(?!\d)/
        let numeric = /(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{4}|\d{2})(?![\d\/.-])/
        let named = /(?i)(\d{1,2})[ -]([a-z]{3,9})[ ,-]+(\d{4}|\d{2})(?!\d)/

        func startsCleanly(_ range: Range<String.Index>) -> Bool {
            range.lowerBound == line.startIndex
                || !line[line.index(before: range.lowerBound)].isNumber
        }

        for match in line.matches(of: iso) where startsCleanly(match.range) {
            guard let y = Int(match.output.1), let m = Int(match.output.2),
                  let d = Int(match.output.3) else { continue }
            found.append((y, m, d, false))
        }
        for match in line.matches(of: numeric) where startsCleanly(match.range) {
            guard let d = Int(match.output.1), let m = Int(match.output.2),
                  let rawYear = Int(match.output.3) else { continue }
            let y = match.output.3.count == 2 ? 2000 + rawYear : rawYear
            found.append((y, m, d, d <= 12 && m <= 12 && d != m))
        }
        for match in line.matches(of: named) where startsCleanly(match.range) {
            let name = match.output.2.lowercased()
            guard let d = Int(match.output.1), let rawYear = Int(match.output.3),
                  let m = months[String(name.prefix(3))] else { continue }
            let y = match.output.3.count == 2 ? 2000 + rawYear : rawYear
            found.append((y, m, d, false))
        }

        let today = startOfDay(now)
        guard let earliest = calendar.date(byAdding: .year, value: -7, to: today) else { return [] }
        return found.compactMap { y, m, d, ambiguous in
            guard let date = noon(y, m, d),
                  startOfDay(date) <= today,
                  date >= earliest else { return nil }
            return DateCandidate(date: date, ambiguous: ambiguous)
        }
    }

    private static func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }
}
```

`"SST ID W10-1808-32000123"` is the case to watch: `10-18` is followed by `0`, not a separator, and every later start (`08-32…`, `8-32…`) is preceded by a digit, so nothing is read. `"2025-03-14"` is read once, by `iso` — `numeric` cannot start at `25` because a digit precedes it. The tests prove both.

A note on `matches(of:)`: it finds non-overlapping matches, so when a candidate is refused by `startsCleanly` the regex does not retry inside it. That is what we want — a refused run is not a date anywhere.

- [ ] **Step 4: Run to see it pass**

Run: `swift test --filter ReceiptDateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TaxCapture/Parsing/ReceiptDate.swift Tests/TaxCaptureTests/ReceiptDateTests.swift
git commit -m "feat(capture): read day-first dates in English and Malay off a receipt line

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Rows, and the parser that reads total, date and vendor

**Files:**
- Modify: `Package.swift` (give `TaxCaptureTests` `resources: [.copy("Fixtures")]`)
- Create: `Sources/TaxCapture/Parsing/Phrase.swift`
- Create: `Sources/TaxCapture/Parsing/RowAssembler.swift`
- Create: `Sources/TaxCapture/Parsing/ReceiptParser.swift`
- Create: `Tests/TaxCaptureTests/Fixtures/receipts/*.json` (13 files, below)
- Test: `Tests/TaxCaptureTests/RowAssemblerTests.swift`
- Test: `Tests/TaxCaptureTests/ReceiptParserTests.swift`

**Interfaces:**
- Consumes: `OCRLine`, `Reading`, `ReadingSource`, `ReceiptAmount.amounts(in:)` (Task 1); `ReceiptDate.dates(in:now:)`, `ReceiptDate.noon` (Task 2).
- Produces:
  - `struct Phrase` (internal): `init(_ text: String)`, `func contains(_ phrase: String) -> Bool`, `func first(of phrases: [String]) -> String?`, `func containsAny(_ phrases: [String]) -> Bool`, `var words: [Substring]`.
  - `public struct TextFragment: Hashable, Sendable { text: String; page: Int; left: Double; top: Double; bottom: Double; confidence: Double }` — top-origin, 0–1.
  - `public enum RowAssembler { static func lines(from fragments: [TextFragment]) -> [OCRLine] }`
  - `public struct ReceiptFields: Hashable, Sendable { total: Reading<Money>?; date: Reading<Date>?; vendor: Reading<String>?; totalCandidates: [Money] }`
  - `public enum ReceiptParser { static func parse(_ lines: [OCRLine], now: Date) -> ReceiptFields }`

- [ ] **Step 1: Give the test target its fixtures**

In `Package.swift`, change the `TaxCaptureTests` target to:

```swift
        .testTarget(
            name: "TaxCaptureTests",
            dependencies: ["TaxCapture"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
```

- [ ] **Step 2: Write the failing row-assembly tests**

Vision returns a receipt row as separate observations when there is a wide gap — `TOTAL` on the left, `18.40` on the right. Parsing needs them as one line.

`Tests/TaxCaptureTests/RowAssemblerTests.swift`:

```swift
import Testing
@testable import TaxCapture

@Suite("Rejoining a row Vision split") struct RowAssemblerTests {

    static func fragment(_ text: String, left: Double, top: Double,
                         height: Double = 0.02, page: Int = 0,
                         confidence: Double = 1) -> TextFragment {
        TextFragment(text: text, page: page, left: left, top: top,
                     bottom: top + height, confidence: confidence)
    }

    @Test("a label and its amount on one row become one line, left to right")
    func joinsARow() {
        let lines = RowAssembler.lines(from: [
            Self.fragment("18.40", left: 0.8, top: 0.501),
            Self.fragment("TOTAL", left: 0.1, top: 0.500),
        ])
        #expect(lines.map(\.text) == ["TOTAL 18.40"])
        #expect(lines.first?.top == 0.500)
    }

    @Test("rows further apart than half a line stay separate, top to bottom")
    func keepsRowsApart() {
        let lines = RowAssembler.lines(from: [
            Self.fragment("CASH 20.00", left: 0.1, top: 0.53),
            Self.fragment("TOTAL 18.40", left: 0.1, top: 0.50),
        ])
        #expect(lines.map(\.text) == ["TOTAL 18.40", "CASH 20.00"])
    }

    @Test("a row is as sure as its least sure fragment")
    func confidenceIsTheMinimum() {
        let lines = RowAssembler.lines(from: [
            Self.fragment("TOTAL", left: 0.1, top: 0.5, confidence: 0.9),
            Self.fragment("18.40", left: 0.8, top: 0.5, confidence: 0.4),
        ])
        #expect(lines.first?.confidence == 0.4)
    }

    @Test("pages are never merged, and come in order")
    func pagesStaySeparate() {
        let lines = RowAssembler.lines(from: [
            Self.fragment("PAGE TWO", left: 0.1, top: 0.1, page: 1),
            Self.fragment("PAGE ONE", left: 0.1, top: 0.1, page: 0),
        ])
        #expect(lines.map(\.text) == ["PAGE ONE", "PAGE TWO"])
        #expect(lines.map(\.page) == [0, 1])
    }
}
```

- [ ] **Step 3: Run to see it fail**

Run: `swift test --filter RowAssemblerTests`
Expected: FAIL — `cannot find 'TextFragment' in scope`.

- [ ] **Step 4: Implement `Phrase` and `RowAssembler`**

`Sources/TaxCapture/Parsing/Phrase.swift`:

```swift
import Foundation

/// Text reduced to upper-case words, so a label matches as a whole word.
///
/// `" TOTAL "` is searched for in `" SUB TOTAL 18 40 "`, which is why `SUB-TOTAL` must be
/// excluded before `TOTAL` is looked for, and why `TOTAL` never matches inside `SUBTOTAL`.
/// Punctuation becomes a space: `SDN. BHD.` and `SDN BHD` are the same phrase.
struct Phrase {
    let padded: String

    init(_ text: String) {
        let mapped = String(text.uppercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
        padded = " " + mapped.split(separator: " ").joined(separator: " ") + " "
    }

    var words: [Substring] { padded.split(separator: " ") }

    func contains(_ phrase: String) -> Bool { padded.contains(Phrase(phrase).padded) }

    func containsAny(_ phrases: [String]) -> Bool { phrases.contains(where: contains) }

    func first(of phrases: [String]) -> String? { phrases.first(where: contains) }
}
```

`Sources/TaxCapture/Parsing/RowAssembler.swift`:

```swift
import Foundation

/// One piece of text as the recogniser returned it, before rows are rebuilt.
public struct TextFragment: Hashable, Sendable {
    public var text: String
    public var page: Int
    /// 0 to 1 across the page.
    public var left: Double
    /// 0 to 1 down the page — top-origin, already flipped from Vision's bottom-left.
    public var top: Double
    public var bottom: Double
    public var confidence: Double

    public init(text: String, page: Int, left: Double, top: Double,
                bottom: Double, confidence: Double) {
        self.text = text
        self.page = page
        self.left = left
        self.top = top
        self.bottom = bottom
        self.confidence = confidence
    }
}

/// Rebuilds printed rows from fragments.
///
/// A till receipt puts the label at the left margin and the amount at the right, and
/// Vision often returns them as two observations. Two fragments share a row when their
/// vertical centres are within half the smaller one's height.
public enum RowAssembler {

    public static func lines(from fragments: [TextFragment]) -> [OCRLine] {
        struct Row {
            var page: Int
            var top: Double
            var bottom: Double
            var members: [TextFragment]
        }

        var rows: [Row] = []
        let ordered = fragments.sorted { ($0.page, $0.top, $0.left) < ($1.page, $1.top, $1.left) }
        for fragment in ordered {
            let centre = (fragment.top + fragment.bottom) / 2
            let height = fragment.bottom - fragment.top
            // The row keeps its first fragment's band, so a long row cannot drift down
            // the page one slightly-lower fragment at a time.
            if let index = rows.lastIndex(where: { row in
                row.page == fragment.page
                    && abs((row.top + row.bottom) / 2 - centre)
                        <= min(row.bottom - row.top, height) / 2
            }) {
                rows[index].members.append(fragment)
            } else {
                rows.append(Row(page: fragment.page, top: fragment.top,
                                bottom: fragment.bottom, members: [fragment]))
            }
        }

        return rows
            .sorted { ($0.page, $0.top) < ($1.page, $1.top) }
            .map { row in
                let members = row.members.sorted { $0.left < $1.left }
                return OCRLine(text: members.map(\.text).joined(separator: " "),
                               page: row.page,
                               top: row.top,
                               confidence: members.map(\.confidence).min() ?? 0)
            }
    }
}
```

- [ ] **Step 5: Run to see it pass**

Run: `swift test --filter RowAssemblerTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/TaxCapture/Parsing/Phrase.swift \
  Sources/TaxCapture/Parsing/RowAssembler.swift Tests/TaxCaptureTests/RowAssemblerTests.swift
git commit -m "feat(capture): rejoin receipt rows Vision returns in pieces

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 7: Write the fixture corpus**

Each fixture is a receipt's lines, top to bottom, and what the parser must read from it. The loader gives line *i* of *n* `top = i / n`, page 0, confidence 1 — so "top third" is the first third of the lines. `totalConfirmed` etc. pin the confidence band: `true` means ≥ 0.7, `false` means below, `null` means the field must be absent.


`Tests/TaxCaptureTests/Fixtures/receipts/supermarket.json`:

```json
{
  "lines": [
    "AEON CO. (M) BHD (126926-H)",
    "AEON MALL SHAH ALAM",
    "NO. 1 JALAN AKUATIK 13/64",
    "40100 SHAH ALAM, SELANGOR",
    "TEL: 03-5510 7800",
    "SST ID: W10-1808-31000123",
    "TAX INVOICE",
    "14/03/2025 18:42  POS 12  TRANS 3391",
    "MILO 1KG                 17.90",
    "BREAD WHOLEMEAL           4.50",
    "DISC                      4.00-",
    "SUB-TOTAL                18.40",
    "TOTAL                    18.40",
    "CASH                     20.00",
    "CHANGE                    1.60",
    "THANK YOU. PLEASE COME AGAIN"
  ],
  "expect": {
    "total": "18.40",
    "totalConfirmed": true,
    "date": "2025-03-14",
    "dateConfirmed": true,
    "vendor": "AEON CO. (M) BHD",
    "vendorConfirmed": true
  }
}
```

`Tests/TaxCaptureTests/Fixtures/receipts/pharmacy.json`:

```json
{
  "lines": [
    "WATSON'S PERSONAL CARE STORES SDN BHD",
    "(179023-W)",
    "LOT G-12, SUNWAY PYRAMID",
    "47500 PETALING JAYA",
    "SIMPLIFIED TAX INVOICE",
    "INVOICE NO: 00482-1193",
    "DATE: 21/05/2025  TIME: 14:05",
    "PANADOL ACTIFAST 20S       12.90",
    "VITAMIN C 1000MG 30S       41.35",
    "SUB TOTAL                  54.25",
    "SST 6%                      3.26",
    "GRAND TOTAL                57.51",
    "VISA ****1234              57.51"
  ],
  "expect": {
    "total": "57.51",
    "totalConfirmed": true,
    "date": "2025-05-21",
    "dateConfirmed": true,
    "vendor": "WATSON'S PERSONAL CARE STORES SDN BHD",
    "vendorConfirmed": true
  }
}
```

`Tests/TaxCaptureTests/Fixtures/receipts/bookshop.json`:

```json
{
  "lines": [
    "MPH BOOKSTORES SDN BHD",
    "MID VALLEY MEGAMALL",
    "59200 KUALA LUMPUR",
    "RESIT RASMI",
    "TARIKH 07 Mac 2025",
    "THE MALAYSIAN TAX GUIDE    59.90",
    "PENSIL 2B X2               12.00",
    "JUMLAH                     71.90",
    "TUNAI                     100.00",
    "BAKI                       28.10"
  ],
  "expect": {
    "total": "71.90",
    "totalConfirmed": true,
    "date": "2025-03-07",
    "dateConfirmed": true,
    "vendor": "MPH BOOKSTORES SDN BHD",
    "vendorConfirmed": true
  }
}
```

`Tests/TaxCaptureTests/Fixtures/receipts/clinic.json`:

```json
{
  "lines": [
    "KLINIK MEDIVIRON",
    "NO 12 JALAN SS 15/4",
    "47500 SUBANG JAYA, SELANGOR",
    "TEL 03-5633 1122",
    "RECEIPT",
    "2025-04-09 10:15",
    "CONSULTATION               45.00",
    "MEDICATION                 32.50",
    "TOTAL AMOUNT PAYABLE       77.50",
    "PAID BY CARD               77.50"
  ],
  "expect": {
    "total": "77.50",
    "totalConfirmed": true,
    "date": "2025-04-09",
    "dateConfirmed": true,
    "vendor": "KLINIK MEDIVIRON",
    "vendorConfirmed": false
  }
}
```

`Tests/TaxCaptureTests/Fixtures/receipts/bm-only.json`:

```json
{
  "lines": [
    "KEDAI BUKU ILMU ENTERPRISE",
    "(SA0123456-X)",
    "NO 5 JALAN BESAR",
    "16800 PASIR PUTEH KELANTAN",
    "RESIT",
    "TARIKH: 28-OGOS-2024",
    "BUKU LATIHAN               15.00",
    "MAJALAH                    12.00",
    "JUMLAH BESAR               27.00",
    "TUNAI                      30.00",
    "BAKI                        3.00"
  ],
  "expect": {
    "total": "27.00",
    "totalConfirmed": true,
    "date": "2024-08-28",
    "dateConfirmed": true,
    "vendor": "KEDAI BUKU ILMU ENTERPRISE",
    "vendorConfirmed": true
  }
}
```

`Tests/TaxCaptureTests/Fixtures/receipts/chinese-vendor.json`:

```json
{
  "lines": [
    "大众书局 POPULAR BOOK CO. (M) SDN BHD",
    "(113354-H)",
    "LOT 2.19 1 UTAMA SHOPPING CENTRE",
    "47800 PETALING JAYA",
    "TAX INVOICE",
    "DATE 21/01/2025",
    "BOOK: 三体                 39.90",
    "TOTAL                      39.90",
    "CARD                       39.90"
  ],
  "expect": {
    "total": "39.90",
    "totalConfirmed": true,
    "date": "2025-01-21",
    "dateConfirmed": true,
    "vendor": "大众书局 POPULAR BOOK CO. (M) SDN BHD",
    "vendorConfirmed": true
  }
}
```

`Tests/TaxCaptureTests/Fixtures/receipts/rounding.json`:

```json
{
  "lines": [
    "99 SPEED MART SDN BHD",
    "NO 22 JALAN MERANTI",
    "TAMAN SRI GOMBAK",
    "68100 BATU CAVES",
    "RECEIPT",
    "DATE: 14/06/2025",
    "MAGGI KARI 5S               6.50",
    "MINYAK MASAK 2KG           17.48",
    "TOTAL                      23.98",
    "ROUNDING                    0.02",
    "TOTAL                      24.00",
    "CASH                       50.00",
    "CHANGE                     26.00"
  ],
  "expect": {
    "total": "24.00",
    "totalConfirmed": true,
    "date": "2025-06-14",
    "dateConfirmed": true,
    "vendor": "99 SPEED MART SDN BHD",
    "vendorConfirmed": true
  }
}
```

`Tests/TaxCaptureTests/Fixtures/receipts/service-charge.json`:

```json
{
  "lines": [
    "SUSHI KING SDN BHD",
    "IOI CITY MALL",
    "62502 PUTRAJAYA",
    "TAX INVOICE",
    "DATE: 18/05/2025",
    "SALMON SUSHI               22.80",
    "CHAWANMUSHI                 7.90",
    "RAMEN                      48.10",
    "SUBTOTAL                   78.80",
    "SERVICE CHARGE 10%          7.88",
    "SST 8%                      6.60",
    "TOTAL (INCL. SST)          93.28",
    "VISA                       93.28"
  ],
  "expect": {
    "total": "93.28",
    "totalConfirmed": true,
    "date": "2025-05-18",
    "dateConfirmed": true,
    "vendor": "SUSHI KING SDN BHD",
    "vendorConfirmed": true
  }
}
```

`Tests/TaxCaptureTests/Fixtures/receipts/unlabelled-total.json`:

```json
{
  "lines": [
    "PASAR MALAM STALL 12",
    "NASI LEMAK AYAM             8.50",
    "TEH TARIK                   2.50"
  ],
  "expect": {
    "total": "8.50",
    "totalConfirmed": false,
    "date": null,
    "dateConfirmed": null,
    "vendor": "PASAR MALAM STALL 12",
    "vendorConfirmed": false
  }
}
```

`Tests/TaxCaptureTests/Fixtures/receipts/no-total.json`:

```json
{
  "lines": [
    "PARKING TICKET",
    "ENTRY 09:12",
    "EXIT 11:40",
    "THANK YOU"
  ],
  "expect": {
    "total": null,
    "totalConfirmed": null,
    "date": null,
    "dateConfirmed": null,
    "vendor": "PARKING TICKET",
    "vendorConfirmed": false
  }
}
```

`Tests/TaxCaptureTests/Fixtures/receipts/conflicting-totals.json`:

```json
{
  "lines": [
    "KEDAI RUNCIT AH HOCK",
    "TAMAN MELATI",
    "RECEIPT",
    "DATE 22/04/2025",
    "GULA 2KG                    6.00",
    "BERAS 10KG                 39.00",
    "TOTAL                      45.00",
    "TELUR 30S                   9.00",
    "TOTAL                      54.00"
  ],
  "expect": {
    "total": "54.00",
    "totalConfirmed": false,
    "date": "2025-04-22",
    "dateConfirmed": true,
    "vendor": "KEDAI RUNCIT AH HOCK",
    "vendorConfirmed": false
  }
}
```

`Tests/TaxCaptureTests/Fixtures/receipts/ambiguous-date.json`:

```json
{
  "lines": [
    "FITNESS FIRST MALAYSIA SDN BHD",
    "(591489-K)",
    "MENARA PJ",
    "46350 PETALING JAYA",
    "OFFICIAL RECEIPT",
    "DATE: 04/05/2025",
    "MONTHLY MEMBERSHIP        199.00",
    "TOTAL                     199.00"
  ],
  "expect": {
    "total": "199.00",
    "totalConfirmed": true,
    "date": "2025-05-04",
    "dateConfirmed": false,
    "vendor": "FITNESS FIRST MALAYSIA SDN BHD",
    "vendorConfirmed": true
  }
}
```

`Tests/TaxCaptureTests/Fixtures/receipts/future-date.json`:

```json
{
  "lines": [
    "TADIKA CERIA ENTERPRISE",
    "NO 3 JALAN MAWAR",
    "RESIT",
    "DATE: 20/07/2025",
    "YURAN BULAN JULAI         350.00",
    "JUMLAH                    350.00",
    "DICETAK 15/06/2025 09:00"
  ],
  "expect": {
    "total": "350.00",
    "totalConfirmed": true,
    "date": null,
    "dateConfirmed": null,
    "vendor": "TADIKA CERIA ENTERPRISE",
    "vendorConfirmed": true
  }
}
```


- [ ] **Step 8: Write the failing parser tests**

`Tests/TaxCaptureTests/ReceiptParserTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
@testable import TaxCapture

struct ReceiptFixture: Decodable {
    struct Expectation: Decodable {
        var total: String?
        var totalConfirmed: Bool?
        var date: String?
        var dateConfirmed: Bool?
        var vendor: String?
        var vendorConfirmed: Bool?
    }

    var lines: [String]
    var expect: Expectation

    static let names = [
        "supermarket", "pharmacy", "bookshop", "clinic", "bm-only", "chinese-vendor",
        "rounding", "service-charge", "unlabelled-total", "no-total",
        "conflicting-totals", "ambiguous-date", "future-date",
    ]

    static func load(_ name: String) throws -> ReceiptFixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures/receipts"))
        return try JSONDecoder().decode(ReceiptFixture.self, from: Data(contentsOf: url))
    }

    var ocrLines: [OCRLine] {
        lines.enumerated().map { index, text in
            OCRLine(text: text, page: 0, top: Double(index) / Double(lines.count), confidence: 1)
        }
    }
}

@Suite("Reading a receipt's fields") struct ReceiptParserTests {

    /// 15 June 2025, the suite-wide test clock.
    static let now = Date(timeIntervalSince1970: 1_750_000_000)

    static func money(_ text: String) -> Money? { ReceiptAmount.amounts(in: text).first }

    static func date(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        return ReceiptDate.noon(parts[0], parts[1], parts[2])
    }

    @Test("each receipt in the corpus reads as expected", arguments: ReceiptFixture.names)
    func corpus(name: String) throws {
        let fixture = try ReceiptFixture.load(name)
        let fields = ReceiptParser.parse(fixture.ocrLines, now: Self.now)
        let expect = fixture.expect

        #expect(fields.total?.value == expect.total.flatMap(Self.money), "total")
        #expect(fields.total?.isConfirmed == expect.totalConfirmed, "total band")
        #expect(fields.date?.value == expect.date.flatMap(Self.date), "date")
        #expect(fields.date?.isConfirmed == expect.dateConfirmed, "date band")
        #expect(fields.vendor?.value == expect.vendor, "vendor")
        #expect(fields.vendor?.isConfirmed == expect.vendorConfirmed, "vendor band")
    }

    @Test("a label alone on its line takes the amount on the next")
    func labelOnItsOwnLine() {
        let fields = ReceiptParser.parse([OCRLine(text: "TOTAL"), OCRLine(text: "RM 18.40")],
                                         now: Self.now)
        #expect(fields.total?.value == Money(sen: 1_840))
        #expect(fields.total?.source == .label("TOTAL"))
    }

    @Test("a grand total beats a total, whichever comes first")
    func rankOneWins() {
        let fields = ReceiptParser.parse([OCRLine(text: "GRAND TOTAL 90.10"),
                                          OCRLine(text: "TOTAL 85.00")], now: Self.now)
        #expect(fields.total?.value == Money(sen: 9_010))
        #expect(fields.total?.confidence == 0.95)
    }

    /// The recogniser was unsure of the very characters that make up the figure.
    @Test("a total read with low recogniser confidence is not confirmed")
    func lowLineConfidenceCaps() {
        let fields = ReceiptParser.parse([OCRLine(text: "TOTAL 18.40", confidence: 0.4)],
                                         now: Self.now)
        #expect(fields.total?.value == Money(sen: 1_840))
        #expect(fields.total?.isConfirmed == false)
    }

    @Test("two different dates on one receipt leave the chosen one unconfirmed")
    func severalDatesCap() {
        let fields = ReceiptParser.parse([OCRLine(text: "DATE: 14/03/2025"),
                                          OCRLine(text: "ORDER 12/03/2025")], now: Self.now)
        #expect(fields.date?.value == ReceiptDate.noon(2025, 3, 14))
        #expect(fields.date?.isConfirmed == false)
    }

    @Test("the model is offered every labelled total, best first, once each")
    func candidatesForTheModel() {
        let fields = ReceiptParser.parse([OCRLine(text: "TOTAL 45.00"),
                                          OCRLine(text: "TOTAL 54.00"),
                                          OCRLine(text: "TOTAL 54.00")], now: Self.now)
        #expect(fields.totalCandidates == [Money(sen: 5_400), Money(sen: 4_500)])
    }

    @Test("nothing to read reads as nothing")
    func emptyInput() {
        #expect(ReceiptParser.parse([], now: Self.now) == ReceiptFields())
    }
}
```

- [ ] **Step 9: Run to see it fail**

Run: `swift test --filter ReceiptParserTests`
Expected: FAIL — `cannot find 'ReceiptParser' in scope`.

- [ ] **Step 10: Implement the parser**

`Sources/TaxCapture/Parsing/ReceiptParser.swift`:

```swift
import Foundation
import TaxKit

/// What the parser read off a receipt. Every field may be absent: a field that was not
/// found is left blank for the user, never guessed at.
public struct ReceiptFields: Hashable, Sendable {
    public var total: Reading<Money>?
    public var date: Reading<Date>?
    public var vendor: Reading<String>?
    /// Every total the parser considered, best first, each once. What the on-device
    /// model may choose among — it may never supply a number of its own.
    public var totalCandidates: [Money]

    public init(total: Reading<Money>? = nil, date: Reading<Date>? = nil,
                vendor: Reading<String>? = nil, totalCandidates: [Money] = []) {
        self.total = total
        self.date = date
        self.vendor = vendor
        self.totalCandidates = totalCandidates
    }
}

/// A deterministic reader for Malaysian till receipts. Spec §4.
///
/// Rules, not a model: every decision here is pinned by a fixture, so a receipt that
/// reads wrongly becomes a fixture and a fix rather than a shrug.
public enum ReceiptParser {

    public static func parse(_ lines: [OCRLine], now: Date) -> ReceiptFields {
        let (total, candidates) = readTotal(lines)
        return ReceiptFields(total: total,
                             date: readDate(lines, now: now),
                             vendor: readVendor(lines),
                             totalCandidates: candidates)
    }

    // MARK: - Total

    static let grandTotals = ["GRAND TOTAL", "JUMLAH BESAR", "TOTAL AMOUNT PAYABLE", "NET TOTAL"]
    static let plainTotals = ["TOTAL", "JUMLAH", "AMOUNT DUE", "AMAUN"]
    static let roundingWords = ["ROUNDING", "PELARASAN"]
    /// Lines that carry an amount and are never the total.
    static let notTotals = [
        "SUBTOTAL", "SUB TOTAL", "TAX", "SST", "GST", "CUKAI",
        "SERVICE CHARGE", "CAJ PERKHIDMATAN", "DISCOUNT", "DISKAUN", "DISC",
        "CHANGE", "BAKI", "CASH", "TUNAI", "TENDERED", "CARD", "VISA", "MASTER",
        "MASTERCARD", "SAVINGS", "QTY", "KUANTITI",
    ] + roundingWords

    private struct Candidate {
        var amount: Money
        var rank: Int
        var label: String
        var index: Int
        var lineConfidence: Double
    }

    /// A total line with its tax note removed. `TOTAL (INCL. SST) 93.28` is the total; left
    /// alone, the `SST` in it would exclude the line. A bracket that holds an amount is
    /// kept, since that amount may be the figure.
    static func totalLineText(_ text: String) -> String {
        var cleaned = text.replacing(/\([^()]*\)/) { match in
            ReceiptAmount.amounts(in: String(match.output)).isEmpty ? " " : String(match.output)
        }
        cleaned = cleaned.replacing(
            /(?i)\bINCL(?:USIVE|\.)?\s*(?:OF\s+)?(?:SST|GST|TAX)\b/, with: " ")
        return cleaned
    }

    private static func label(of phrase: Phrase) -> (rank: Int, label: String)? {
        if let label = phrase.first(of: grandTotals) { return (1, label) }
        if let label = phrase.first(of: plainTotals) { return (2, label) }
        return nil
    }

    private static func lastPositive(_ text: String) -> Money? {
        ReceiptAmount.amounts(in: text).last { $0 > .zero }
    }

    static func readTotal(_ lines: [OCRLine]) -> (Reading<Money>?, [Money]) {
        var candidates: [Candidate] = []
        var roundingIndex: Int?

        for (index, line) in lines.enumerated() {
            let text = totalLineText(line.text)
            let phrase = Phrase(text)
            if phrase.containsAny(roundingWords) { roundingIndex = index }
            if phrase.containsAny(notTotals) { continue }
            guard let found = label(of: phrase) else { continue }

            if let amount = lastPositive(text) {
                candidates.append(Candidate(amount: amount, rank: found.rank, label: found.label,
                                            index: index, lineConfidence: line.confidence))
            } else if index + 1 < lines.count {
                // `TOTAL` on its own line, the figure on the next.
                let next = lines[index + 1]
                let nextText = totalLineText(next.text)
                let nextPhrase = Phrase(nextText)
                guard !nextPhrase.containsAny(notTotals), label(of: nextPhrase) == nil,
                      let amount = lastPositive(nextText) else { continue }
                candidates.append(Candidate(amount: amount, rank: found.rank, label: found.label,
                                            index: index + 1,
                                            lineConfidence: min(line.confidence, next.confidence)))
            }
        }

        guard !candidates.isEmpty else { return fallbackTotal(lines) }

        // With a rounding line, the total printed after it is the one paid.
        var pool = candidates
        if let roundingIndex {
            let after = candidates.filter { $0.index > roundingIndex }
            if !after.isEmpty { pool = after }
        }

        let bestRank = pool.map(\.rank).min() ?? 2
        let top = pool.filter { $0.rank == bestRank }
        let chosen: Candidate
        var confidence: Double
        if Set(top.map(\.amount)).count == 1, let only = top.last {
            chosen = only
            confidence = bestRank == 1 ? 0.95 : 0.85
        } else {
            // Two totals of the same standing disagree. The larger is usually the one
            // after a late item; either way the user must look.
            chosen = top.max { $0.amount < $1.amount } ?? top[0]
            confidence = 0.55
        }
        if chosen.lineConfidence < 0.6 { confidence = min(confidence, 0.6) }

        let ordered = candidates.sorted { ($0.rank, -$0.index) < ($1.rank, -$1.index) }
        return (Reading(value: chosen.amount, confidence: confidence, source: .label(chosen.label)),
                unique(ordered.map(\.amount)))
    }

    /// No labelled total at all: the largest amount on the receipt, as a last resort, and
    /// never confirmed.
    private static func fallbackTotal(_ lines: [OCRLine]) -> (Reading<Money>?, [Money]) {
        let amounts = lines
            .filter { !Phrase(totalLineText($0.text)).containsAny(notTotals) }
            .flatMap { ReceiptAmount.amounts(in: $0.text) }
            .filter { $0 > .zero }
        guard let largest = amounts.max() else { return (nil, []) }
        return (Reading(value: largest, confidence: 0.4, source: .heuristic),
                Array(unique(amounts.sorted(by: >)).prefix(5)))
    }

    private static func unique(_ amounts: [Money]) -> [Money] {
        var seen: Set<Money> = []
        return amounts.filter { seen.insert($0).inserted }
    }

    // MARK: - Date

    static let dateLabels = ["DATE", "TARIKH"]
    /// A date on one of these lines is not when the money was spent.
    static let notDates = ["EXP", "EXPIRY", "EXPIRES", "TAMAT", "DUE", "PRINT", "PRINTED",
                           "CETAK", "DICETAK", "VALID UNTIL", "BEST BEFORE"]

    static func readDate(_ lines: [OCRLine], now: Date) -> Reading<Date>? {
        struct Found { var candidate: DateCandidate; var label: String?; var lineConfidence: Double }

        var found: [Found] = []
        for line in lines {
            let phrase = Phrase(line.text)
            if phrase.containsAny(notDates) { continue }
            let label = phrase.first(of: dateLabels)
            for candidate in ReceiptDate.dates(in: line.text, now: now) {
                found.append(Found(candidate: candidate, label: label,
                                   lineConfidence: line.confidence))
            }
        }

        guard let best = found.first(where: { $0.label != nil }) ?? found.first else { return nil }
        var confidence = best.label != nil ? 0.9 : 0.8
        if best.candidate.ambiguous { confidence -= 0.25 }
        if Set(found.map(\.candidate.date)).count > 1 { confidence = min(confidence, 0.6) }
        if best.lineConfidence < 0.6 { confidence = min(confidence, 0.6) }
        return Reading(value: best.candidate.date, confidence: confidence,
                       source: best.label.map(ReadingSource.label) ?? .heuristic)
    }

    // MARK: - Vendor

    static let titles = ["TAX INVOICE", "INVOICE", "INVOIS", "RESIT", "RECEIPT", "CASH BILL",
                         "BIL", "WELCOME", "SELAMAT DATANG", "COPY", "SALINAN"]
    static let addressWords = [
        "JALAN", "JLN", "LORONG", "LRG", "TAMAN", "TMN", "PERSIARAN", "LEBUH", "LEBUHRAYA",
        "BANDAR", "NO", "LOT", "MALL", "PLAZA", "MENARA",
        "KUALA LUMPUR", "SELANGOR", "JOHOR", "PULAU PINANG", "PENANG", "PERAK", "KEDAH",
        "KELANTAN", "TERENGGANU", "PAHANG", "MELAKA", "NEGERI SEMBILAN", "SABAH",
        "SARAWAK", "PERLIS", "PUTRAJAYA", "LABUAN", "WILAYAH PERSEKUTUAN",
    ]
    static let phoneWords = ["TEL", "PHONE", "FAX", "HP", "H P", "MOBILE", "WHATSAPP"]
    static let idWords = ["SST ID", "GST ID", "SST NO", "GST NO", "REG NO", "CO NO",
                          "COMPANY NO", "ROC", "BRN", "TIN"]
    static let companySuffixes = ["SDN BHD", "BERHAD", "BHD", "ENTERPRISE", "ENTERPRISES",
                                  "PLT", "TRADING"]

    /// The registration number in brackets goes: `AEON CO. (M) BHD (126926-H)` is
    /// `AEON CO. (M) BHD`. A bracket with no digit — `(M)` — stays.
    static func cleanVendor(_ text: String) -> String {
        text.replacing(/\([^)]*\d[^)]*\)/, with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func readVendor(_ lines: [OCRLine]) -> Reading<String>? {
        let skip = titles + addressWords + phoneWords + idWords
        let candidates: [(name: String, confidence: Double)] = lines
            .filter { $0.page == 0 && $0.top < 1.0 / 3.0 }
            .compactMap { line in
                let name = cleanVendor(line.text)
                let visible = name.filter { !$0.isWhitespace }
                guard !visible.isEmpty,
                      Double(visible.filter(\.isLetter).count) / Double(visible.count) >= 0.6
                else { return nil }
                let phrase = Phrase(name)
                guard !phrase.containsAny(skip),
                      !phrase.words.contains(where: { $0.count == 5 && $0.allSatisfy(\.isNumber) })
                else { return nil }
                return (name, line.confidence)
            }

        if let company = candidates.first(where: { Phrase($0.name).containsAny(companySuffixes) }) {
            let suffix = Phrase(company.name).first(of: companySuffixes) ?? ""
            return Reading(value: company.name,
                           confidence: company.confidence < 0.6 ? 0.6 : 0.85,
                           source: .label(suffix))
        }
        guard let first = candidates.first else { return nil }
        return Reading(value: first.name, confidence: 0.6, source: .heuristic)
    }
}
```

If the compiler rejects `\b` inside the `INCL` regex, use `.wordBoundaryKind(.simple)` or drop the `\b`s and anchor with `(?:^|\s)` / `(?=\s|$)`; the service-charge fixture proves the behaviour either way.

- [ ] **Step 11: Run to see it pass**

Run: `swift test --filter ReceiptParserTests`
Expected: PASS — all 13 fixtures and the six unit cases. If a fixture fails, fix the parser, never the fixture's expectation; the expectations are the spec.

- [ ] **Step 12: Commit**

```bash
git add Sources/TaxCapture/Parsing/ReceiptParser.swift \
  Tests/TaxCaptureTests/ReceiptParserTests.swift Tests/TaxCaptureTests/Fixtures/receipts
git commit -m "feat(capture): read total, date and vendor off a receipt, pinned by a fixture corpus

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The MyInvois QR link

**Files:**
- Create: `Sources/TaxCapture/Parsing/MyInvoisLink.swift`
- Test: `Tests/TaxCaptureTests/MyInvoisLinkTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct MyInvoisLink: Hashable, Sendable { let uuid: String; let longId: String; init?(_ payload: String) }`

- [ ] **Step 1: Write the failing tests**

`Tests/TaxCaptureTests/MyInvoisLinkTests.swift`:

```swift
import Testing
@testable import TaxCapture

/// The QR on a MyInvois e-invoice is a validation link, `{portal}/{uuid}/share/{longId}`,
/// and nothing else. Offline, the document ID is all it gives — spec §2 and §4.
///
/// MyInvois IDs are not RFC 4122 UUIDs. LHDN's own API example is `F9D425P6DS7D8IU`.
@Suite("The MyInvois QR link") struct MyInvoisLinkTests {

    static let longId = "RZ6FQYX9J1G6V3K8H2M4T7W0C5B9N1P3"

    @Test("production and preprod links are accepted")
    func acceptsBothPortals() throws {
        let production = try #require(MyInvoisLink(
            "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/\(Self.longId)"))
        #expect(production.uuid == "F9D425P6DS7D8IU")
        #expect(production.longId == Self.longId)
        #expect(MyInvoisLink(
            "https://preprod.myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/\(Self.longId)") != nil)
    }

    @Test("the host is case-insensitive and surrounding whitespace is ignored")
    func tolerant() {
        #expect(MyInvoisLink(
            "  https://MyInvois.Hasil.gov.my/F9D425P6DS7D8IU/share/\(Self.longId)\n")?.uuid
            == "F9D425P6DS7D8IU")
    }

    @Test("anything else is not a MyInvois link", arguments: [
        "http://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://myinvois.hasil.gov.my.example.com/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://example.com/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4/extra",
        "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4/",
        "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/view/RZ6FQYX9J1G6V3K8H2M4",
        "https://myinvois.hasil.gov.my/F9D4-25P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4?x=1",
        "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4#top",
        "https://myinvois.hasil.gov.my:8443/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://someone@myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://myinvois.hasil.gov.my/SHORT/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/SHORT",
        "WIFI:S:CafeGuest;T:WPA;P:secret;;",
        "",
    ])
    func rejects(payload: String) {
        #expect(MyInvoisLink(payload) == nil)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter MyInvoisLinkTests`
Expected: FAIL — `cannot find 'MyInvoisLink' in scope`.

- [ ] **Step 3: Implement**

`Sources/TaxCapture/Parsing/MyInvoisLink.swift`:

```swift
import Foundation

/// A MyInvois validation link read from an e-invoice's QR code.
///
/// Strict on purpose. A QR is attacker-controllable input — anyone can print one — and
/// the only thing this does with it is record an ID, so accepting a near-miss buys
/// nothing and risks recording a stranger's string as an e-invoice. Nothing here opens
/// the link: spec §2, no network.
public struct MyInvoisLink: Hashable, Sendable {
    public let uuid: String
    public let longId: String

    static let hosts: Set<String> = ["myinvois.hasil.gov.my", "preprod.myinvois.hasil.gov.my"]

    public init?(_ payload: String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), Self.hosts.contains(host),
              parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil
        else { return nil }

        let path = parts.percentEncodedPath
        guard path.hasPrefix("/"), !path.hasSuffix("/") else { return nil }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[1] == "share",
              segments[0].wholeMatch(of: /[A-Za-z0-9]{10,40}/) != nil,
              segments[2].wholeMatch(of: /[A-Za-z0-9]{10,200}/) != nil
        else { return nil }

        uuid = String(segments[0])
        longId = String(segments[2])
    }
}
```

- [ ] **Step 4: Run to see it pass**

Run: `swift test --filter MyInvoisLinkTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TaxCapture/Parsing/MyInvoisLink.swift Tests/TaxCaptureTests/MyInvoisLinkTests.swift
git commit -m "feat(capture): recognise a MyInvois validation link, strictly and offline

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Suggesting reliefs from a receipt

**Files:**
- Create: `Sources/TaxCapture/Parsing/ReliefSuggester.swift`
- Test: `Tests/TaxCaptureTests/ReliefSuggesterTests.swift`

**Interfaces:**
- Consumes: `Phrase` (Task 3); `TaxKit.RuleSet.relief(for:)`, `ReliefRule.automatic`, `ReliefCode` constants, `BundledRuleSetLoader` (tests).
- Produces: `public enum ReliefSuggester { static func suggest(vendor: String?, text: String, in ruleSet: RuleSet) -> [ReliefCode] }` — at most 3, in order, never automatic, always present in `ruleSet`.

- [ ] **Step 1: Write the failing tests**

`Tests/TaxCaptureTests/ReliefSuggesterTests.swift`:

```swift
import Testing
import TaxKit
@testable import TaxCapture

@Suite("Suggesting reliefs from a receipt") struct ReliefSuggesterTests {

    static func rules(_ year: Int) throws -> RuleSet {
        try BundledRuleSetLoader().ruleSet(for: year)
    }

    @Test("each keyword row, against YA 2025", arguments: [
        ("KLINIK MEDIVIRON", [ReliefCode.medicalSerious, .medicalCheckup]),
        ("HOSPITAL PANTAI", [.medicalSerious, .medicalCheckup]),
        ("TOOTH DENTAL SURGERY", [.medicalDental]),
        ("KLINIK PERGIGIAN SENYUM", [.medicalDental, .medicalSerious, .medicalCheckup]),
        ("PUSAT VAKSIN", [.medicalVaccination]),
        ("KEDAI BUKU ILMU", [.lifestyle]),
        ("MPH BOOKSTORES", [.lifestyle]),
        ("LAPTOP WORLD", [.lifestyle]),
        ("ANYTIME GYM", [.lifestyleSports]),
        ("DECATHLON", [.lifestyleSports]),
        ("TADIKA CERIA", [.childcare]),
        ("GENTARI", [.evCharging]),
        ("UNIVERSITI MALAYA", [.educationSelf]),
        ("PERBADANAN SSPN", [.sspn]),
        ("PAM SUSU MURAH", [.breastfeeding]),
        ("ETIQA TAKAFUL", [.insuranceEduMedical, .lifeInsurance]),
    ])
    func rows(vendor: String, expected: [ReliefCode]) throws {
        #expect(ReliefSuggester.suggest(vendor: vendor, text: "", in: try Self.rules(2025))
                == expected)
    }

    @Test("a keyword matches a whole word only")
    func wholeWords() throws {
        #expect(ReliefSuggester.suggest(vendor: "BOOKING.COM", text: "", in: try Self.rules(2025))
                .isEmpty)
    }

    @Test("no match means no suggestions, not a guess")
    func noMatch() throws {
        #expect(ReliefSuggester.suggest(vendor: nil, text: "", in: try Self.rules(2025)).isEmpty)
        #expect(ReliefSuggester.suggest(vendor: "99 SPEED MART", text: "MILO 1KG",
                                        in: try Self.rules(2025)).isEmpty)
    }

    @Test("the vendor's matches come before the text's")
    func vendorFirst() throws {
        #expect(ReliefSuggester.suggest(vendor: "ANYTIME GYM", text: "BUKU LATIHAN",
                                        in: try Self.rules(2025))
                == [.lifestyleSports, .lifestyle])
    }

    @Test("never more than three")
    func atMostThree() throws {
        let codes = ReliefSuggester.suggest(vendor: "KLINIK PERGIGIAN", text: "VAKSIN BUKU",
                                            in: try Self.rules(2025))
        #expect(codes == [.medicalDental, .medicalSerious, .medicalCheckup])
    }

    /// MEDICAL_DENTAL first appears in YA 2024. A 2023 dental receipt must not suggest a
    /// relief that year's picker cannot even show.
    @Test("a code absent from that year's rulebook is never suggested")
    func respectsTheYear() throws {
        #expect(ReliefSuggester.suggest(vendor: "DENTAL CARE", text: "",
                                        in: try Self.rules(2023)).isEmpty)
    }

    @Test("an automatic relief is never suggested")
    func neverAutomatic() throws {
        let table = [ReliefSuggester.Row(keywords: ["ANYTHING"], codes: [.selfAndDependents])]
        #expect(ReliefSuggester.suggest(vendor: "ANYTHING", text: "",
                                        in: try Self.rules(2025), table: table).isEmpty)
    }

    @Test("every suggestion in every year is claimable", arguments: [2023, 2024, 2025])
    func everyRowIsClaimable(year: Int) throws {
        let rules = try Self.rules(year)
        for row in ReliefSuggester.table {
            for keyword in row.keywords {
                for code in ReliefSuggester.suggest(vendor: keyword, text: "", in: rules) {
                    let rule = try #require(rules.relief(for: code), "\(code) in \(year)")
                    #expect(rule.automatic == false, "\(code) in \(year)")
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter ReliefSuggesterTests`
Expected: FAIL — `cannot find 'ReliefSuggester' in scope`.

- [ ] **Step 3: Implement**

`Sources/TaxCapture/Parsing/ReliefSuggester.swift`:

```swift
import Foundation
import TaxKit

/// Relief *candidates* from a receipt's words. Never a choice: the editor shows them
/// first in the picker and the user picks.
///
/// Straight to codes, not through `ReliefCategory` — that lives in `TaxPresentation`,
/// and a family is too coarse: "Health" holds eight reliefs and a dental receipt belongs
/// to one of them. Spec §4.
///
/// There is deliberately no pharmacy row. A pharmacy receipt is as often shampoo as
/// medicine, and a wrong suggestion at the top of the picker is worse than none.
public enum ReliefSuggester {

    struct Row {
        var keywords: [String]
        var codes: [ReliefCode]
    }

    /// Order matters: within one piece of text, earlier rows' codes come first. Dental and
    /// vaccination sit above the general clinic row so "KLINIK PERGIGIAN" leads with dental.
    static let table: [Row] = [
        Row(keywords: ["DENTAL", "PERGIGIAN", "DENTIST"], codes: [.medicalDental]),
        Row(keywords: ["VAKSIN", "VACCINE", "VACCINATION"], codes: [.medicalVaccination]),
        Row(keywords: ["KLINIK", "CLINIC", "HOSPITAL", "MEDICAL CENTRE", "PUSAT PERUBATAN"],
            codes: [.medicalSerious, .medicalCheckup]),
        Row(keywords: ["BUKU", "BOOK", "BOOKS", "BOOKSTORE", "BOOKSTORES", "MPH", "POPULAR",
                       "KINOKUNIYA", "MAJALAH", "MAGAZINE",
                       "COMPUTER", "KOMPUTER", "LAPTOP", "SMARTPHONE", "BROADBAND", "UNIFI"],
            codes: [.lifestyle]),
        Row(keywords: ["GYM", "FITNESS", "DECATHLON", "SPORTS", "SUKAN", "BADMINTON", "SWIMMING"],
            codes: [.lifestyleSports]),
        Row(keywords: ["TADIKA", "TASKA", "NURSERY", "CHILDCARE", "PUSAT JAGAAN",
                       "KINDERGARTEN", "PRESCHOOL"],
            codes: [.childcare]),
        Row(keywords: ["EV CHARGING", "EV CHARGER", "CHARGEEV", "GENTARI"], codes: [.evCharging]),
        Row(keywords: ["UNIVERSITI", "UNIVERSITY", "KOLEJ", "COLLEGE", "YURAN PENGAJIAN",
                       "TUITION FEE"],
            codes: [.educationSelf]),
        Row(keywords: ["SSPN", "PTPTN"], codes: [.sspn]),
        Row(keywords: ["BREAST PUMP", "PAM SUSU"], codes: [.breastfeeding]),
        Row(keywords: ["INSURANCE", "INSURANS", "TAKAFUL"],
            codes: [.insuranceEduMedical, .lifeInsurance]),
    ]

    public static func suggest(vendor: String?, text: String, in ruleSet: RuleSet) -> [ReliefCode] {
        suggest(vendor: vendor, text: text, in: ruleSet, table: table)
    }

    static func suggest(vendor: String?, text: String, in ruleSet: RuleSet,
                        table: [Row]) -> [ReliefCode] {
        var codes: [ReliefCode] = []
        for phrase in [Phrase(vendor ?? ""), Phrase(text)] {
            for row in table where phrase.containsAny(row.keywords) {
                codes += row.codes
            }
        }
        var seen: Set<ReliefCode> = []
        return Array(codes
            .filter { seen.insert($0).inserted }
            .filter { code in ruleSet.relief(for: code).map { !$0.automatic } ?? false }
            .prefix(3))
    }
}
```

- [ ] **Step 4: Run to see it pass**

Run: `swift test --filter ReliefSuggesterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TaxCapture/Parsing/ReliefSuggester.swift Tests/TaxCaptureTests/ReliefSuggesterTests.swift
git commit -m "feat(capture): suggest up to three claimable reliefs from a receipt's words

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Normalising what was captured, and a receipt to test with

**Files:**
- Create: `Sources/TaxCapture/Reading/CaptureInput.swift`
- Create: `Sources/TaxCapture/Reading/ImageCoding.swift`
- Create: `Sources/TaxCapture/Reading/PDFPageRenderer.swift`
- Create: `Sources/TaxCapture/Reading/ImageNormaliser.swift`
- Create: `Sources/TaxCapture/Reading/SampleReceipt.swift`
- Test: `Tests/TaxCaptureTests/ImageNormaliserTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public enum CaptureInput: Hashable, Sendable { case image(Data), pdf(Data), scannedPages([Data]) }`
  - `public enum CaptureError: Error, Hashable, Sendable { case unreadableImage, unreadablePDF }`
  - `public struct NormalisedDocument: Hashable, Sendable { data: Data; uti: String; fileExtension: String; thumbnail: Data?; pageImages: [Data]; textSource: TextSource }` with `public enum TextSource: Hashable, Sendable { case pageImages, pdfTextLayer }`. `pageImages` are upright JPEGs: every page for a photo or scan; page one only (for its QR) for a PDF file.
  - `public protocol ImageNormalising: Sendable { func normalise(_ input: CaptureInput) throws -> NormalisedDocument }` and `public struct ImageNormaliser: ImageNormalising` with `static let maxPixel = 2000`, `static let thumbnailPixel = 320`.
  - `enum ImageCoding` (internal): `decode(_ data: Data, maxPixel: Int) -> CGImage?` (applies EXIF orientation), `jpeg(_ image: CGImage, quality: Double) -> Data?`, `png(_ image: CGImage) -> Data?`.
  - `enum PDFPageRenderer` (internal): `document(_ data: Data) -> CGPDFDocument?`, `render(_ document: CGPDFDocument, pageIndex: Int, maxPixel: Int) -> CGImage?`, `pdf(from images: [CGImage]) -> Data?`.
  - `public enum SampleReceipt` (`#if DEBUG`): `static let lines: [String]`, `image(lines:qr:) -> CGImage?`, `jpeg(lines:qr:) -> Data?`, `png(lines:qr:) -> Data?`, `pdf(lines:textLayer:pages:) -> Data?`.

- [ ] **Step 1: Write the failing tests**

`Tests/TaxCaptureTests/ImageNormaliserTests.swift`:

```swift
#if canImport(ImageIO) && canImport(CoreText)
import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import TaxCapture

/// Spec §6, normalising. A receipt photo carries GPS in its EXIF and the store should not;
/// and because metadata is stripped, an iPhone's "rotate me" tag has to be *applied*, or
/// every portrait receipt is stored lying on its side.
@Suite("Normalising a captured receipt") struct ImageNormaliserTests {

    /// A solid image of the given size, encoded as JPEG with whatever properties are given.
    static func jpeg(width: Int, height: Int, properties: [CFString: Any] = [:]) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func size(_ data: Data) -> (width: Int, height: Int) {
        let props = properties(data)
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    @Test("a photo tagged to be rotated is stored upright, with no orientation tag left")
    func orientationIsApplied() throws {
        // Stored 400 × 200 with orientation 6: the camera held portrait, the sensor wrote
        // landscape. Upright, that is 200 wide and 400 tall.
        let photo = Self.jpeg(width: 400, height: 200,
                              properties: [kCGImagePropertyOrientation: 6])
        let normalised = try ImageNormaliser().normalise(.image(photo))
        let size = Self.size(normalised.data)
        #expect(size.width == 200)
        #expect(size.height == 400)
        let orientation = Self.properties(normalised.data)[kCGImagePropertyOrientation] as? Int
        #expect(orientation == nil || orientation == 1)
    }

    @Test("location and every other metadata block are stripped")
    func metadataIsStripped() throws {
        let photo = Self.jpeg(width: 300, height: 300, properties: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 3.139,
                                            kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 101.687,
                                            kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private"],
        ])
        #expect(Self.properties(photo)[kCGImagePropertyGPSDictionary] != nil,
                "the fixture itself must carry GPS, or this test proves nothing")
        let normalised = try ImageNormaliser().normalise(.image(photo))
        let props = Self.properties(normalised.data)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(normalised.uti == "public.jpeg")
        #expect(normalised.fileExtension == "jpg")
        #expect(normalised.textSource == .pageImages)
        #expect(normalised.pageImages == [normalised.data])
    }

    @Test("the long edge is capped at 2000 px, and a small photo is not enlarged")
    func longEdgeIsCapped() throws {
        let large = try ImageNormaliser().normalise(.image(Self.jpeg(width: 4000, height: 3000)))
        #expect(Self.size(large.data) == (2000, 1500))
        let small = try ImageNormaliser().normalise(.image(Self.jpeg(width: 640, height: 480)))
        #expect(Self.size(small.data) == (640, 480))
    }

    @Test("the thumbnail is 320 px on its long edge and under 30 KB")
    func thumbnailIsSmall() throws {
        let receipt = try #require(SampleReceipt.jpeg())
        let normalised = try ImageNormaliser().normalise(.image(receipt))
        let thumbnail = try #require(normalised.thumbnail)
        let size = Self.size(thumbnail)
        #expect(max(size.width, size.height) == 320)
        #expect(thumbnail.count < 30_000)
    }

    @Test("a PDF is stored byte for byte, with page one as its thumbnail")
    func pdfIsStoredUnchanged() throws {
        let pdf = try #require(SampleReceipt.pdf(textLayer: true))
        let normalised = try ImageNormaliser().normalise(.pdf(pdf))
        #expect(normalised.data == pdf)
        #expect(normalised.uti == "com.adobe.pdf")
        #expect(normalised.fileExtension == "pdf")
        #expect(normalised.textSource == .pdfTextLayer)
        let thumbnail = try #require(normalised.thumbnail)
        #expect(max(Self.size(thumbnail).width, Self.size(thumbnail).height) == 320)
        // Page one, rendered, so the pipeline can look for a QR on it.
        #expect(normalised.pageImages.count == 1)
    }

    @Test("one scanned page is a JPEG; several become one PDF, each page still readable")
    func scannedPages() throws {
        let page = try #require(SampleReceipt.jpeg())
        let one = try ImageNormaliser().normalise(.scannedPages([page]))
        #expect(one.uti == "public.jpeg")
        #expect(one.pageImages.count == 1)

        let three = try ImageNormaliser().normalise(.scannedPages([page, page, page]))
        #expect(three.uti == "com.adobe.pdf")
        #expect(three.textSource == .pageImages)
        #expect(three.pageImages.count == 3)
        let document = try #require(PDFPageRenderer.document(three.data))
        #expect(document.numberOfPages == 3)
    }

    @Test("bytes that are not an image or a PDF are refused")
    func garbageIsRefused() {
        let garbage = Data("not a receipt".utf8)
        #expect(throws: CaptureError.unreadableImage) {
            try ImageNormaliser().normalise(.image(garbage))
        }
        #expect(throws: CaptureError.unreadablePDF) {
            try ImageNormaliser().normalise(.pdf(garbage))
        }
        #expect(throws: CaptureError.unreadableImage) {
            try ImageNormaliser().normalise(.scannedPages([]))
        }
    }
}
#endif
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter ImageNormaliserTests`
Expected: FAIL — `cannot find 'ImageNormaliser' in scope`.

- [ ] **Step 3: Write the input and output types**

`Sources/TaxCapture/Reading/CaptureInput.swift`:

```swift
import Foundation

/// What the user handed over, before anything has been done to it.
public enum CaptureInput: Hashable, Sendable {
    /// A photo from the library, or any file ImageIO can decode.
    case image(Data)
    /// A PDF from Files — usually born-digital, with a text layer.
    case pdf(Data)
    /// The document camera's pages, one image each, in order.
    case scannedPages([Data])
}

/// The input could not be decoded at all. The only failure the pipeline throws for;
/// everything after this point fails softly. Spec §6.
public enum CaptureError: Error, Hashable, Sendable {
    case unreadableImage
    case unreadablePDF
}

/// What gets stored, and what gets read.
public struct NormalisedDocument: Hashable, Sendable {

    /// Where the text comes from.
    public enum TextSource: Hashable, Sendable {
        /// OCR every image in `pageImages`.
        case pageImages
        /// A PDF from Files: its text layer first, OCR only for a page without one.
        case pdfTextLayer
    }

    /// The bytes to write to `DocumentFileStore`: a stripped JPEG, or a PDF.
    public var data: Data
    public var uti: String
    public var fileExtension: String
    /// 320 px long edge, JPEG. The only image bytes that would ever sync.
    public var thumbnail: Data?
    /// Upright JPEGs to read: every page of a photo or scan, or page one of a PDF file —
    /// rendered only so the pipeline can look for a MyInvois QR on it.
    public var pageImages: [Data]
    public var textSource: TextSource

    public init(data: Data, uti: String, fileExtension: String, thumbnail: Data?,
                pageImages: [Data], textSource: TextSource) {
        self.data = data
        self.uti = uti
        self.fileExtension = fileExtension
        self.thumbnail = thumbnail
        self.pageImages = pageImages
        self.textSource = textSource
    }
}
```

- [ ] **Step 4: Write the image and PDF helpers**

`Sources/TaxCapture/Reading/ImageCoding.swift`:

```swift
#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO, used the one way this package needs it.
enum ImageCoding {

    /// Decodes, applies the EXIF orientation and shrinks to `maxPixel` on the long edge,
    /// in one pass. Never enlarges.
    ///
    /// `CreateThumbnailWithTransform` is what applies the orientation. Without it the
    /// pixels come back as the sensor wrote them, and since `jpeg(_:)` writes no metadata
    /// the rotation would be lost rather than kept as a tag.
    static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG with no properties copied across — no EXIF, no GPS, no orientation tag.
    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        encode(image, type: .jpeg,
               properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    static func png(_ image: CGImage) -> Data? {
        encode(image, type: .png, properties: [:])
    }

    private static func encode(_ image: CGImage, type: UTType,
                               properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
```

`Sources/TaxCapture/Reading/PDFPageRenderer.swift`:

```swift
import CoreGraphics
import Foundation

/// PDF pages to pixels and pixels to PDF pages, with CoreGraphics alone, so it builds
/// wherever the package does.
enum PDFPageRenderer {

    static func document(_ data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else { return nil }
        return document
    }

    /// One page on white, `maxPixel` on its long edge. `pageIndex` is zero-based;
    /// CoreGraphics' own page numbers start at 1.
    ///
    /// A page's `/Rotate` is not applied. Till receipts and e-invoices are portrait and
    /// unrotated; if one turns up rotated it becomes a fixture and a fix.
    static func render(_ document: CGPDFDocument, pageIndex: Int, maxPixel: Int) -> CGImage? {
        guard let page = document.page(at: pageIndex + 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = Double(maxPixel) / Double(max(box.width, box.height))
        let width = Int((Double(box.width) * scale).rounded())
        let height = Int((Double(box.height) * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// Several scanned pages as one PDF, one image per page at its own size.
    static func pdf(from images: [CGImage]) -> Data? {
        guard !images.isEmpty else { return nil }
        let data = NSMutableData()
        var defaultBox = CGRect(x: 0, y: 0, width: images[0].width, height: images[0].height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &defaultBox, nil)
        else { return nil }
        for image in images {
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }
}
```

- [ ] **Step 5: Write the normaliser**

`Sources/TaxCapture/Reading/ImageNormaliser.swift`:

```swift
import Foundation

public protocol ImageNormalising: Sendable {
    /// - Throws: `CaptureError` when the input cannot be decoded at all.
    func normalise(_ input: CaptureInput) throws -> NormalisedDocument
}

#if canImport(ImageIO)
import CoreGraphics

/// Spec §6: images to a 2000 px long edge, re-encoded as JPEG with every piece of
/// metadata dropped; PDFs stored unchanged. The hash is taken of *these* bytes, by
/// `DocumentFileStore.write`, so the same photo imported twice is still one file.
public struct ImageNormaliser: ImageNormalising {

    public static let maxPixel = 2000
    public static let thumbnailPixel = 320
    static let quality = 0.8
    static let thumbnailQuality = 0.6

    public init() {}

    public func normalise(_ input: CaptureInput) throws -> NormalisedDocument {
        switch input {
        case .image(let data):
            return try image(data)

        case .pdf(let data):
            guard let document = PDFPageRenderer.document(data) else {
                throw CaptureError.unreadablePDF
            }
            let pageOne = PDFPageRenderer.render(document, pageIndex: 0, maxPixel: Self.maxPixel)
                .flatMap { ImageCoding.jpeg($0, quality: Self.quality) }
            let thumbnail = PDFPageRenderer.render(document, pageIndex: 0,
                                                   maxPixel: Self.thumbnailPixel)
                .flatMap { ImageCoding.jpeg($0, quality: Self.thumbnailQuality) }
            return NormalisedDocument(data: data, uti: "com.adobe.pdf", fileExtension: "pdf",
                                      thumbnail: thumbnail,
                                      pageImages: pageOne.map { [$0] } ?? [],
                                      textSource: .pdfTextLayer)

        case .scannedPages(let pages):
            guard !pages.isEmpty else { throw CaptureError.unreadableImage }
            if pages.count == 1 { return try image(pages[0]) }

            var images: [CGImage] = []
            var jpegs: [Data] = []
            for page in pages {
                guard let decoded = ImageCoding.decode(page, maxPixel: Self.maxPixel),
                      let jpeg = ImageCoding.jpeg(decoded, quality: Self.quality)
                else { throw CaptureError.unreadableImage }
                images.append(decoded)
                jpegs.append(jpeg)
            }
            guard let pdf = PDFPageRenderer.pdf(from: images) else {
                throw CaptureError.unreadableImage
            }
            return NormalisedDocument(data: pdf, uti: "com.adobe.pdf", fileExtension: "pdf",
                                      thumbnail: Self.thumbnail(of: jpegs[0]),
                                      pageImages: jpegs, textSource: .pageImages)
        }
    }

    private func image(_ data: Data) throws -> NormalisedDocument {
        guard let decoded = ImageCoding.decode(data, maxPixel: Self.maxPixel),
              let jpeg = ImageCoding.jpeg(decoded, quality: Self.quality)
        else { throw CaptureError.unreadableImage }
        return NormalisedDocument(data: jpeg, uti: "public.jpeg", fileExtension: "jpg",
                                  thumbnail: Self.thumbnail(of: jpeg),
                                  pageImages: [jpeg], textSource: .pageImages)
    }

    static func thumbnail(of data: Data) -> Data? {
        ImageCoding.decode(data, maxPixel: thumbnailPixel)
            .flatMap { ImageCoding.jpeg($0, quality: thumbnailQuality) }
    }
}
#endif
```

- [ ] **Step 6: Write the sample receipt**

A real receipt, drawn from text, so the adapters can be run for real in `swift test` (spec §7) and the `-relio-scan` harness has something to scan. DEBUG only.

`Sources/TaxCapture/Reading/SampleReceipt.swift`:

```swift
#if DEBUG && canImport(CoreText) && canImport(ImageIO)
import CoreGraphics
import CoreText
import Foundation
#if canImport(CoreImage)
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

/// A receipt drawn from lines of text, with an optional QR under it. For tests and the
/// screenshot harness only — never compiled into a release build.
///
/// The date, 07/03/2025, is deliberately ambiguous (both numbers ≤ 12), so the harness
/// screenshot shows an unconfirmed field next to confirmed ones.
public enum SampleReceipt {

    public static let lines = [
        "MPH BOOKSTORES SDN BHD",
        "(197901006384)",
        "MID VALLEY MEGAMALL",
        "59200 KUALA LUMPUR",
        "TEL: 03-2938 3818",
        "TAX INVOICE",
        "DATE: 07/03/2025  14:22",
        "THE HOBBIT          49.90",
        "NOTEBOOK A5         22.00",
        "TOTAL RM            71.90",
        "CASH               100.00",
        "CHANGE              28.10",
    ]

    static let width = 1000.0
    static let margin = 60.0
    static let lineHeight = 56.0
    static let fontSize = 34.0
    static let qrSide = 320.0

    static func height(lineCount: Int, hasQR: Bool) -> Double {
        margin * 2 + Double(lineCount) * lineHeight + (hasQR ? qrSide + margin : 0)
    }

    public static func image(lines: [String] = lines, qr: String? = nil) -> CGImage? {
        let height = height(lineCount: lines.count, hasQR: qr != nil)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(width), height: Int(height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(lines, qr: qr, in: context, height: height)
        return context.makeImage()
    }

    public static func jpeg(lines: [String] = lines, qr: String? = nil) -> Data? {
        image(lines: lines, qr: qr).flatMap { ImageCoding.jpeg($0, quality: 0.9) }
    }

    public static func png(lines: [String] = lines, qr: String? = nil) -> Data? {
        image(lines: lines, qr: qr).flatMap(ImageCoding.png)
    }

    /// - Parameter textLayer: true draws real text into the PDF, as a born-digital
    ///   e-invoice has; false draws the receipt as a picture, as a scan saved to PDF has.
    public static func pdf(lines: [String] = lines, textLayer: Bool, pages: Int = 1) -> Data? {
        guard textLayer else {
            guard let picture = image(lines: lines) else { return nil }
            return PDFPageRenderer.pdf(from: Array(repeating: picture, count: pages))
        }
        let data = NSMutableData()
        let height = height(lineCount: lines.count, hasQR: false)
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return nil }
        for _ in 0..<pages {
            context.beginPage(mediaBox: &box)
            draw(lines, qr: nil, in: context, height: height)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func draw(_ lines: [String], qr: String?, in context: CGContext,
                             height: Double) {
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.textMatrix = .identity
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            context.textPosition = CGPoint(x: margin,
                                           y: height - margin - Double(index + 1) * lineHeight)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        #if canImport(CoreImage)
        if let qr, let code = qrImage(qr) {
            context.interpolationQuality = .none
            context.draw(code, in: CGRect(x: margin, y: margin, width: qrSide, height: qrSide))
        }
        #endif
    }

    #if canImport(CoreImage)
    private static func qrImage(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
    #endif
}
#endif
```

- [ ] **Step 7: Run to see it pass**

Run: `swift test --filter ImageNormaliserTests`
Expected: PASS, 7 tests.

Then look at the sample receipt once, since everything downstream reads it. Add this temporary line to `thumbnailIsSmall`, run `swift test --filter ImageNormaliserTests`, and remove the line before committing:

```swift
try receipt.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "relio-sample.jpg"))
```

Open `$TMPDIR/relio-sample.jpg` with the Read tool and check: all twelve lines present, the right-hand amounts not clipped at the right margin, the last line (`CHANGE 28.10`) fully inside the bottom edge. Remove the line.

- [ ] **Step 8: Commit**

```bash
git add Sources/TaxCapture/Reading/CaptureInput.swift Sources/TaxCapture/Reading/ImageCoding.swift \
  Sources/TaxCapture/Reading/PDFPageRenderer.swift Sources/TaxCapture/Reading/ImageNormaliser.swift \
  Sources/TaxCapture/Reading/SampleReceipt.swift Tests/TaxCaptureTests/ImageNormaliserTests.swift
git commit -m "feat(capture): normalise receipts upright and stripped, with a 320 px thumbnail

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Reading text and QR codes for real

**Files:**
- Create: `Sources/TaxCapture/Reading/TextReading.swift`
- Create: `Sources/TaxCapture/Reading/VisionTextReader.swift`
- Create: `Sources/TaxCapture/Reading/VisionBarcodeReader.swift`
- Create: `Sources/TaxCapture/Reading/PDFTextReader.swift`
- Test: `Tests/TaxCaptureTests/AdapterTests.swift`

**Interfaces:**
- Consumes: `TextFragment`, `RowAssembler`, `OCRLine` (Task 3); `ImageCoding`, `PDFPageRenderer`, `ImageNormaliser.maxPixel`, `CaptureError`, `SampleReceipt` (Task 6); `ReceiptParser` (Task 3, test only).
- Produces:
  - `public protocol TextReading: Sendable { func fragments(inImage data: Data, page: Int) async throws -> [TextFragment] }`
  - `public protocol BarcodeReading: Sendable { func qrPayloads(inImage data: Data) async throws -> [String] }`
  - `public protocol PDFTextReading: Sendable { func lines(inPDF data: Data) async throws -> [OCRLine] }`
  - `public struct VisionTextReader: TextReading`, `public struct VisionBarcodeReader: BarcodeReading` (`#if canImport(Vision)`)
  - `public struct PDFTextReader: PDFTextReading` with `init(ocr: any TextReading)` and `static let ocrPageLimit = 5` (`#if canImport(PDFKit)`)

- [ ] **Step 1: Write the failing tests**

These run Vision for real on macOS. They assert that the text and the payload come back, not Vision's exact output.

`Tests/TaxCaptureTests/AdapterTests.swift`:

```swift
#if canImport(Vision) && canImport(PDFKit)
import Testing
import Foundation
import TaxKit
@testable import TaxCapture

/// Counts calls and returns nothing, so a test can see how much OCR a reader asked for.
actor CountingTextReader: TextReading {
    private(set) var calls = 0
    nonisolated func fragments(inImage data: Data, page: Int) async throws -> [TextFragment] {
        await record()
        return []
    }
    private func record() { calls += 1 }
}

@Suite("Reading text and codes for real") struct AdapterTests {

    static let link = "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4T7W0"
    static let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("Vision reads the sample receipt, and the parser finds its total")
    func visionReadsAPhoto() async throws {
        let png = try #require(SampleReceipt.png())
        let lines = RowAssembler.lines(from: try await VisionTextReader().fragments(inImage: png, page: 0))
        let text = lines.map(\.text).joined(separator: "\n")
        #expect(text.contains("MPH BOOKSTORES"))
        #expect(text.contains("71.90"))
        #expect(ReceiptParser.parse(lines, now: Self.now).total?.value == Money(sen: 7190))
    }

    @Test("Vision finds the QR's payload")
    func qrPayloadIsRead() async throws {
        let png = try #require(SampleReceipt.png(qr: Self.link))
        #expect(try await VisionBarcodeReader().qrPayloads(inImage: png) == [Self.link])
    }

    @Test("a receipt with no QR has no payloads")
    func noQR() async throws {
        let png = try #require(SampleReceipt.png())
        #expect(try await VisionBarcodeReader().qrPayloads(inImage: png).isEmpty)
    }

    @Test("a born-digital PDF is read from its text layer, exactly, with no OCR")
    func textLayerFirst() async throws {
        let pdf = try #require(SampleReceipt.pdf(textLayer: true))
        let ocr = CountingTextReader()
        let lines = try await PDFTextReader(ocr: ocr).lines(inPDF: pdf)
        let texts = lines.map { $0.text.split(separator: " ").joined(separator: " ") }
        #expect(texts.contains("TOTAL RM 71.90"))
        #expect(texts.first == "MPH BOOKSTORES SDN BHD")
        #expect(await ocr.calls == 0)
    }

    @Test("a page with no text layer is OCR'd")
    func imageOnlyPDFIsOCRd() async throws {
        let pdf = try #require(SampleReceipt.pdf(textLayer: false))
        let lines = try await PDFTextReader(ocr: VisionTextReader()).lines(inPDF: pdf)
        #expect(lines.map(\.text).joined(separator: "\n").contains("71.90"))
    }

    /// Review focus 5. A 40-page scanned statement must not mean 40 rounds of OCR.
    @Test("OCR stops after five image-only pages")
    func ocrFallbackStopsAtFivePages() async throws {
        let pdf = try #require(SampleReceipt.pdf(textLayer: false, pages: 40))
        let ocr = CountingTextReader()
        _ = try await PDFTextReader(ocr: ocr).lines(inPDF: pdf)
        #expect(await ocr.calls == PDFTextReader.ocrPageLimit)
        #expect(PDFTextReader.ocrPageLimit == 5)
    }

    @Test("bytes that are not a PDF are refused")
    func notAPDF() async {
        await #expect(throws: CaptureError.unreadablePDF) {
            try await PDFTextReader(ocr: CountingTextReader()).lines(inPDF: Data("x".utf8))
        }
    }
}
#endif
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter AdapterTests`
Expected: FAIL — `cannot find type 'TextReading' in scope`.

- [ ] **Step 3: Write the protocols**

`Sources/TaxCapture/Reading/TextReading.swift`:

```swift
import Foundation

/// OCR over one upright image. Behind a protocol so the pipeline's tests can hand it
/// whatever text they need without Vision.
public protocol TextReading: Sendable {
    func fragments(inImage data: Data, page: Int) async throws -> [TextFragment]
}

/// QR payloads found in one image, as strings. Only QR — a till's barcode is a product
/// code and says nothing about the claim.
public protocol BarcodeReading: Sendable {
    func qrPayloads(inImage data: Data) async throws -> [String]
}

/// A PDF's lines, from its text layer where it has one.
public protocol PDFTextReading: Sendable {
    func lines(inPDF data: Data) async throws -> [OCRLine]
}
```

- [ ] **Step 4: Write the Vision adapters**

`Sources/TaxCapture/Reading/VisionTextReader.swift`:

```swift
#if canImport(Vision)
import Foundation
import Vision

/// Spec §4: accurate recognition, English and both Chinese scripts, language correction
/// off. Malay is Latin script and correction "fixes" it into English — `JUMLAH` is not a
/// typo.
public struct VisionTextReader: TextReading {

    public init() {}

    public func fragments(inImage data: Data, page: Int) async throws -> [TextFragment] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "en-US"),
                                        Locale.Language(identifier: "zh-Hans"),
                                        Locale.Language(identifier: "zh-Hant")]
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: data)
        return observations.compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            // Vision's rectangle is normalised with its origin at the bottom left; rows
            // are rebuilt top to bottom, so flip it here, once.
            let box = observation.boundingBox.cgRect
            return TextFragment(text: best.string,
                                page: page,
                                left: Double(box.minX),
                                top: 1 - Double(box.maxY),
                                bottom: 1 - Double(box.minY),
                                confidence: Double(best.confidence))
        }
    }
}
#endif
```

`Sources/TaxCapture/Reading/VisionBarcodeReader.swift`:

```swift
#if canImport(Vision)
import Foundation
import Vision

public struct VisionBarcodeReader: BarcodeReading {

    public init() {}

    public func qrPayloads(inImage data: Data) async throws -> [String] {
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        return try await request.perform(on: data).compactMap(\.payloadString)
    }
}
#endif
```

- [ ] **Step 5: Write the PDF reader**

`Sources/TaxCapture/Reading/PDFTextReader.swift`:

```swift
#if canImport(PDFKit) && canImport(ImageIO)
import Foundation
import PDFKit

/// Spec §4: the text layer first — a born-digital e-invoice has one and it is exact —
/// and OCR only for a page without one.
///
/// Lines come from PDFKit's per-line selections with their positions, not from
/// `page.string`, so a label and its amount drawn far apart on one row are rejoined by
/// `RowAssembler` the same way Vision's fragments are.
public struct PDFTextReader: PDFTextReading {

    /// A long image-only PDF — a scanned statement — is not worth forty rounds of OCR for
    /// a receipt's three fields, which are on the first page anyway.
    public static let ocrPageLimit = 5

    private let ocr: any TextReading

    public init(ocr: any TextReading) {
        self.ocr = ocr
    }

    public func lines(inPDF data: Data) async throws -> [OCRLine] {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw CaptureError.unreadablePDF
        }
        var lines: [OCRLine] = []
        var pagesOCRd = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let layer = Self.textLayer(of: page, index: index)
            if !layer.isEmpty {
                lines += RowAssembler.lines(from: layer)
                continue
            }
            guard pagesOCRd < Self.ocrPageLimit else { continue }
            pagesOCRd += 1
            guard let rendered = PDFPageRenderer.document(data)
                    .flatMap({ PDFPageRenderer.render($0, pageIndex: index,
                                                      maxPixel: ImageNormaliser.maxPixel) }),
                  let jpeg = ImageCoding.jpeg(rendered, quality: 0.8) else { continue }
            lines += RowAssembler.lines(from: try await ocr.fragments(inImage: jpeg, page: index))
        }
        return lines
    }

    private static func textLayer(of page: PDFPage, index: Int) -> [TextFragment] {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0,
              let selections = page.selection(for: bounds)?.selectionsByLine() else { return [] }
        return selections.compactMap { selection in
            guard let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let rect = selection.bounds(for: page)
            // PDF space has its origin at the bottom left, like Vision's.
            return TextFragment(text: text,
                                page: index,
                                left: Double((rect.minX - bounds.minX) / bounds.width),
                                top: 1 - Double((rect.maxY - bounds.minY) / bounds.height),
                                bottom: 1 - Double((rect.minY - bounds.minY) / bounds.height),
                                confidence: 1)
        }
    }
}
#endif
```

- [ ] **Step 6: Run to see it pass**

Run: `swift test --filter AdapterTests`
Expected: PASS, 7 tests. If `textLayerFirst` fails on the first-line assertion because PDFKit orders selections differently, print `texts` and fix the reader's ordering — `RowAssembler` sorts by `top`, so a wrong order means a wrong `top`, not a test to loosen.

- [ ] **Step 7: Check the package still builds for watchOS**

Run: `swift build --triple arm64-apple-watchos26.0 2>&1 | tail -5` — if the watchOS SDK is not installed, run `xcrun --sdk watchos --show-sdk-path` to confirm, and record in the ledger that this check was not possible rather than skipping it silently.
Expected: `Build complete!` — Vision and PDFKit code is compiled out.

- [ ] **Step 8: Commit**

```bash
git add Sources/TaxCapture/Reading/TextReading.swift Sources/TaxCapture/Reading/VisionTextReader.swift \
  Sources/TaxCapture/Reading/VisionBarcodeReader.swift Sources/TaxCapture/Reading/PDFTextReader.swift \
  Tests/TaxCaptureTests/AdapterTests.swift
git commit -m "feat(capture): read receipt text with Vision and PDFKit, and QR payloads

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: The pipeline

**Files:**
- Create: `Sources/TaxCapture/DocumentPipeline.swift`
- Test: `Tests/TaxCaptureTests/DocumentPipelineTests.swift`

**Interfaces:**
- Consumes: everything in Tasks 1–7.
- Produces:
  - `public enum ReadingStage: Hashable, Sendable { case barcode, text, model }`
  - `public struct ReceiptReading: Hashable, Sendable { document: NormalisedDocument; ocrText: String?; eInvoiceUUID: String?; total: Reading<Money>?; date: Reading<Date>?; vendor: Reading<String>?; totalCandidates: [Money]; suggestedReliefs: [ReliefCode]; failures: Set<ReadingStage>; var couldNotRead: Bool }`
  - `public actor DocumentPipeline { init(normaliser:text:pdfText:barcodes:now:); static func standard() -> DocumentPipeline; func read(_ input: CaptureInput, ruleSet: RuleSet?) async throws -> ReceiptReading }`

- [ ] **Step 1: Write the failing tests**

Stub adapters drive each row of spec §6. The normaliser is the real one: it is pure ImageIO and the sample receipt is small.

`Tests/TaxCaptureTests/DocumentPipelineTests.swift`:

```swift
#if canImport(ImageIO) && canImport(CoreText)
import Testing
import Foundation
import TaxKit
@testable import TaxCapture

struct StubText: TextReading {
    enum Failure: Error { case failed }
    var lines: [String] = []
    var fails = false
    func fragments(inImage data: Data, page: Int) async throws -> [TextFragment] {
        if fails { throw Failure.failed }
        return lines.enumerated().map { index, text in
            let top = Double(index) / Double(max(lines.count, 1))
            return TextFragment(text: text, page: page, left: 0.05, top: top,
                                bottom: top + 0.5 / Double(max(lines.count, 1)), confidence: 1)
        }
    }
}

struct StubBarcodes: BarcodeReading {
    var payloads: [String] = []
    var fails = false
    func qrPayloads(inImage data: Data) async throws -> [String] {
        if fails { throw StubText.Failure.failed }
        return payloads
    }
}

struct StubPDFText: PDFTextReading {
    var lines: [String] = []
    func lines(inPDF data: Data) async throws -> [OCRLine] {
        lines.enumerated().map { OCRLine(text: $1, page: 0,
                                         top: Double($0) / Double(max(lines.count, 1))) }
    }
}

@Suite("The document pipeline") struct DocumentPipelineTests {

    static let now = Date(timeIntervalSince1970: 1_750_000_000)
    static let link = "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4T7W0"

    static func pipeline(text: StubText = StubText(lines: SampleReceipt.lines),
                         barcodes: StubBarcodes = StubBarcodes(),
                         pdfText: StubPDFText = StubPDFText()) -> DocumentPipeline {
        DocumentPipeline(normaliser: ImageNormaliser(), text: text, pdfText: pdfText,
                         barcodes: barcodes, now: { Self.now })
    }

    static func rules() throws -> RuleSet { try BundledRuleSetLoader().ruleSet(for: 2025) }
    static func photo() throws -> CaptureInput { .image(try #require(SampleReceipt.jpeg())) }

    @Test("a readable photo gives its fields, its text and its reliefs")
    func readsAPhoto() async throws {
        let reading = try await Self.pipeline().read(try Self.photo(), ruleSet: try Self.rules())
        #expect(reading.total?.value == Money(sen: 7190))
        #expect(reading.total?.isConfirmed == true)
        #expect(reading.vendor?.value == "MPH BOOKSTORES SDN BHD")
        #expect(reading.date?.value == ReceiptDate.noon(2025, 3, 7))
        #expect(reading.date?.isConfirmed == false, "07/03 could be 3 July")
        #expect(reading.suggestedReliefs == [.lifestyle])
        #expect(reading.ocrText?.contains("TOTAL RM") == true)
        #expect(reading.document.uti == "public.jpeg")
        #expect(reading.document.thumbnail != nil)
        #expect(reading.failures.isEmpty)
        #expect(reading.couldNotRead == false)
    }

    @Test("bytes that cannot be decoded throw, and nothing else does")
    func undecodableThrows() async {
        await #expect(throws: CaptureError.unreadableImage) {
            try await Self.pipeline().read(.image(Data("x".utf8)), ruleSet: nil)
        }
    }

    @Test("no text found: an empty reading, with the file still there to attach")
    func noText() async throws {
        let reading = try await Self.pipeline(text: StubText(lines: []))
            .read(try Self.photo(), ruleSet: try Self.rules())
        #expect(reading.total == nil && reading.date == nil && reading.vendor == nil)
        #expect(reading.ocrText == nil)
        #expect(reading.suggestedReliefs.isEmpty)
        #expect(reading.couldNotRead)
        #expect(!reading.document.data.isEmpty)
    }

    @Test("OCR failing is soft: the failure is recorded and the file is kept")
    func textFailureIsSoft() async throws {
        let reading = try await Self.pipeline(text: StubText(fails: true))
            .read(try Self.photo(), ruleSet: nil)
        #expect(reading.failures == [.text])
        #expect(reading.couldNotRead)
        #expect(!reading.document.data.isEmpty)
    }

    @Test("text with no total or date gives what it has and guesses nothing")
    func partialText() async throws {
        let reading = try await Self.pipeline(text: StubText(lines: ["PARKING TICKET", "LOT B2"]))
            .read(try Self.photo(), ruleSet: nil)
        #expect(reading.total == nil)
        #expect(reading.date == nil)
        #expect(reading.couldNotRead == false)
    }

    @Test("a MyInvois QR sets the e-invoice ID")
    func myInvoisQR() async throws {
        let reading = try await Self.pipeline(barcodes: StubBarcodes(payloads: [Self.link]))
            .read(try Self.photo(), ruleSet: nil)
        #expect(reading.eInvoiceUUID == "F9D425P6DS7D8IU")
    }

    @Test("any other QR is ignored and reading carries on",
          arguments: ["WIFI:S:Guest;T:WPA;P:x;;", "https://example.com/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6"])
    func foreignQRIgnored(payload: String) async throws {
        let reading = try await Self.pipeline(barcodes: StubBarcodes(payloads: [payload]))
            .read(try Self.photo(), ruleSet: nil)
        #expect(reading.eInvoiceUUID == nil)
        #expect(reading.total?.value == Money(sen: 7190))
        #expect(reading.failures.isEmpty)
    }

    @Test("the QR detector failing is soft")
    func barcodeFailureIsSoft() async throws {
        let reading = try await Self.pipeline(barcodes: StubBarcodes(fails: true))
            .read(try Self.photo(), ruleSet: nil)
        #expect(reading.failures == [.barcode])
        #expect(reading.total?.value == Money(sen: 7190))
    }

    @Test("a PDF from Files is read from its text layer, not OCR'd page by page")
    func pdfUsesTheTextLayer() async throws {
        let pdf = try #require(SampleReceipt.pdf(textLayer: true))
        let reading = try await Self.pipeline(text: StubText(fails: true),
                                              pdfText: StubPDFText(lines: ["KLINIK MEDIVIRON",
                                                                           "TOTAL 77.50"]))
            .read(.pdf(pdf), ruleSet: try Self.rules())
        #expect(reading.total?.value == Money(sen: 7750))
        #expect(reading.failures.isEmpty, "the image OCR must not have been called")
        #expect(reading.suggestedReliefs == [.medicalSerious, .medicalCheckup])
        #expect(reading.document.data == pdf)
    }

    @Test("with no rulebook there are no relief suggestions, and nothing else changes")
    func noRuleSet() async throws {
        let reading = try await Self.pipeline().read(try Self.photo(), ruleSet: nil)
        #expect(reading.suggestedReliefs.isEmpty)
        #expect(reading.total?.value == Money(sen: 7190))
    }
}
#endif
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter DocumentPipelineTests`
Expected: FAIL — `cannot find 'DocumentPipeline' in scope`.

- [ ] **Step 3: Implement**

`Sources/TaxCapture/DocumentPipeline.swift`:

```swift
import Foundation
import TaxKit

/// A stage that failed softly. Recorded so the editor can say "Relio couldn't read this
/// receipt" rather than showing silent blanks.
public enum ReadingStage: Hashable, Sendable {
    case barcode
    case text
    case model
}

/// Everything read from one receipt, and the file to keep.
///
/// Carries no content hash: `DocumentFileStore.write` computes that from
/// `document.data`, so there is one SHA-256 in the app rather than two that must agree.
public struct ReceiptReading: Hashable, Sendable {
    public var document: NormalisedDocument
    /// Every line, joined. Nil when no text was found at all.
    public var ocrText: String?
    public var eInvoiceUUID: String?
    public var total: Reading<Money>?
    public var date: Reading<Date>?
    public var vendor: Reading<String>?
    /// For the on-device model to choose among. Never shown.
    public var totalCandidates: [Money]
    /// At most three, best first, never selected for the user.
    public var suggestedReliefs: [ReliefCode]
    public var failures: Set<ReadingStage>

    public init(document: NormalisedDocument, ocrText: String? = nil,
                eInvoiceUUID: String? = nil, total: Reading<Money>? = nil,
                date: Reading<Date>? = nil, vendor: Reading<String>? = nil,
                totalCandidates: [Money] = [], suggestedReliefs: [ReliefCode] = [],
                failures: Set<ReadingStage> = []) {
        self.document = document
        self.ocrText = ocrText
        self.eInvoiceUUID = eInvoiceUUID
        self.total = total
        self.date = date
        self.vendor = vendor
        self.totalCandidates = totalCandidates
        self.suggestedReliefs = suggestedReliefs
        self.failures = failures
    }

    /// No text at all — whether OCR failed or found nothing. Spec §6's second row.
    public var couldNotRead: Bool { ocrText == nil }
}

/// Spec §3: normalise → barcode → text → extract. The file write, and so the hash, is the
/// caller's; this never touches the store.
///
/// Throws only when the input cannot be decoded at all. Every later stage fails softly
/// and the reading still carries the file, so the worst case is exactly today's: a file
/// attached and an editor to fill in by hand.
public actor DocumentPipeline {

    private let normaliser: any ImageNormalising
    private let text: any TextReading
    private let pdfText: any PDFTextReading
    private let barcodes: any BarcodeReading
    private let now: @Sendable () -> Date

    public init(normaliser: any ImageNormalising,
                text: any TextReading,
                pdfText: any PDFTextReading,
                barcodes: any BarcodeReading,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.normaliser = normaliser
        self.text = text
        self.pdfText = pdfText
        self.barcodes = barcodes
        self.now = now
    }

    #if canImport(Vision) && canImport(PDFKit) && canImport(ImageIO)
    /// The real adapters.
    public static func standard() -> DocumentPipeline {
        DocumentPipeline(normaliser: ImageNormaliser(),
                         text: VisionTextReader(),
                         pdfText: PDFTextReader(ocr: VisionTextReader()),
                         barcodes: VisionBarcodeReader())
    }
    #endif

    public func read(_ input: CaptureInput, ruleSet: RuleSet?) async throws -> ReceiptReading {
        let document = try normaliser.normalise(input)
        var failures: Set<ReadingStage> = []

        var eInvoiceUUID: String?
        do {
            for image in document.pageImages where eInvoiceUUID == nil {
                eInvoiceUUID = try await barcodes.qrPayloads(inImage: image)
                    .lazy.compactMap(MyInvoisLink.init).first?.uuid
            }
        } catch {
            failures.insert(.barcode)
        }

        var lines: [OCRLine] = []
        do {
            switch document.textSource {
            case .pdfTextLayer:
                lines = try await pdfText.lines(inPDF: document.data)
            case .pageImages:
                for (page, image) in document.pageImages.enumerated() {
                    lines += RowAssembler.lines(from: try await text.fragments(inImage: image,
                                                                                page: page))
                }
            }
        } catch {
            failures.insert(.text)
            lines = []
        }

        let fields = ReceiptParser.parse(lines, now: now())
        let joined = lines.map(\.text).joined(separator: "\n")
        let ocrText = joined.isEmpty ? nil : joined
        let suggestions = ruleSet.map {
            ReliefSuggester.suggest(vendor: fields.vendor?.value, text: joined, in: $0)
        } ?? []

        return ReceiptReading(document: document,
                              ocrText: ocrText,
                              eInvoiceUUID: eInvoiceUUID,
                              total: fields.total,
                              date: fields.date,
                              vendor: fields.vendor,
                              totalCandidates: fields.totalCandidates,
                              suggestedReliefs: suggestions,
                              failures: failures)
    }
}
```

- [ ] **Step 4: Run to see it pass**

Run: `swift test --filter DocumentPipelineTests`
Expected: PASS, 11 tests.

Then the whole package: `swift test`
Expected: PASS, every suite.

- [ ] **Step 5: Commit**

```bash
git add Sources/TaxCapture/DocumentPipeline.swift Tests/TaxCaptureTests/DocumentPipelineTests.swift
git commit -m "feat(capture): run a receipt through normalise, QR, text and parse, failing softly

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: The store records what was read, and says which claims a receipt already supports

**Files:**
- Modify: `Sources/TaxData/Store/TaxStore+Documents.swift`
- Test: `Tests/TaxDataTests/DocumentAttachmentTests.swift` (add a second suite at the end of the file)

**Interfaces:**
- Consumes: nothing from `TaxCapture` — `TaxData` must not depend on it.
- Produces:
  - `DocumentDraft` gains `public var ocrText: String?` and `public var eInvoiceUUID: String?`, both appended to `init` with default `nil`. `documentDrafts(forEntry:)` returns them.
  - `TaxStore.attach(_:toEntry:)` writes both. Returns the existing document instead of creating one when a live document on the same entry has the same `contentHash` **or** the same non-nil `eInvoiceUUID`.
  - `public struct SupportedClaim: Hashable, Sendable { entryID: UUID; code: ReliefCode; amount: Money; spentOn: Date? }`
  - `TaxStore.claimsSupported(byHash hash: String, orEInvoiceUUID uuid: String?, excludingEntry: UUID?) throws -> [SupportedClaim]` — live documents on live, unmerged entries only; one row per entry; ordered by `spentOn`, earliest first, undated last.
  - `TaxStore.isFileReferenced(hash: String) throws -> Bool` — true if **any** `DocumentFile` row has this hash, soft-deleted or not.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TaxDataTests/DocumentAttachmentTests.swift`:

```swift
/// Spec §3 "Changes to existing code" and §5 "Duplicate warning". The store already
/// had the columns — `Document.ocrText` and `eInvoiceUUID` since Plan 2 — and nothing
/// ever filled them.
@Suite("Documents: what was read, and what else it supports") struct DocumentReadingStoreTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        DocumentAttachmentTests.date(y, m, d)
    }

    static func entry(_ store: TaxStore, ringgit: Decimal = 230,
                      spentOn: Date? = date(2025, 3, 3)) async throws -> UUID {
        try await store.save(EntryDraft(year: 2025, code: .lifestyle,
                                        amount: Money(ringgit: ringgit),
                                        vendor: "MPH", spentOn: spentOn))
    }

    static func receipt(hash: String, uuid: String? = nil) -> DocumentDraft {
        DocumentDraft(kind: .officialReceipt, vendor: "MPH BOOKSTORES SDN BHD",
                      documentDate: date(2025, 3, 3), total: Money(ringgit: 230),
                      byteCount: 48_000, contentHash: hash, uti: "public.jpeg",
                      ocrText: "MPH BOOKSTORES SDN BHD\nTOTAL RM 230.00",
                      eInvoiceUUID: uuid)
    }

    @Test("the receipt's text and e-invoice ID are recorded and read back")
    func readingIsRecorded() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.entry(store)
        _ = try await store.attach(Self.receipt(hash: "h1", uuid: "F9D425P6DS7D8IU"),
                                   toEntry: entryID)
        let document = try #require(try await store.documentDrafts(forEntry: entryID).first)
        #expect(document.ocrText == "MPH BOOKSTORES SDN BHD\nTOTAL RM 230.00")
        #expect(document.eInvoiceUUID == "F9D425P6DS7D8IU")
        #expect(document.kind == .officialReceipt, "a QR never changes the kind")
    }

    /// The same e-invoice downloaded twice as two PDFs: different bytes, one document.
    @Test("the same e-invoice attached twice to one entry is one document")
    func sameEInvoiceAttachesOnce() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.entry(store)
        let first = try await store.attach(Self.receipt(hash: "pdf-a", uuid: "UUID0000001"),
                                           toEntry: entryID)
        let second = try await store.attach(Self.receipt(hash: "pdf-b", uuid: "UUID0000001"),
                                            toEntry: entryID)
        #expect(first == second)
        #expect(try await store.documentDrafts(forEntry: entryID).count == 1)
    }

    @Test("two receipts with no e-invoice ID are not merged on it")
    func nilUUIDsDoNotMatch() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.entry(store)
        _ = try await store.attach(Self.receipt(hash: "a"), toEntry: entryID)
        _ = try await store.attach(Self.receipt(hash: "b"), toEntry: entryID)
        #expect(try await store.documentDrafts(forEntry: entryID).count == 2)
    }

    @Test("a file already on a claim is found by its hash, except on the entry asking")
    func supportedByHash() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.entry(store)
        _ = try await store.attach(Self.receipt(hash: "h1"), toEntry: entryID)

        let claims = try await store.claimsSupported(byHash: "h1", orEInvoiceUUID: nil,
                                                     excludingEntry: nil)
        #expect(claims == [SupportedClaim(entryID: entryID, code: .lifestyle,
                                          amount: Money(ringgit: 230),
                                          spentOn: Self.date(2025, 3, 3))])
        #expect(try await store.claimsSupported(byHash: "h1", orEInvoiceUUID: nil,
                                                excludingEntry: entryID).isEmpty)
        #expect(try await store.claimsSupported(byHash: "other", orEInvoiceUUID: nil,
                                                excludingEntry: nil).isEmpty)
    }

    @Test("a different file of the same e-invoice is found by its ID")
    func supportedByEInvoice() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.entry(store)
        _ = try await store.attach(Self.receipt(hash: "photo", uuid: "UUID0000001"),
                                   toEntry: entryID)
        let claims = try await store.claimsSupported(byHash: "pdf",
                                                     orEInvoiceUUID: "UUID0000001",
                                                     excludingEntry: nil)
        #expect(claims.map(\.entryID) == [entryID])
    }

    @Test("one entry is reported once, and entries come earliest first")
    func oneRowPerEntry() async throws {
        let store = try await StoreFixture.store()
        let later = try await Self.entry(store, ringgit: 100, spentOn: Self.date(2025, 5, 1))
        let earlier = try await Self.entry(store, ringgit: 130, spentOn: Self.date(2025, 3, 3))
        // `later` matches twice — by hash and by e-invoice ID — and is listed once.
        _ = try await store.attach(Self.receipt(hash: "h1", uuid: "UUID0000001"), toEntry: later)
        _ = try await store.attach(Self.receipt(hash: "h1"), toEntry: earlier)

        let claims = try await store.claimsSupported(byHash: "h1", orEInvoiceUUID: "UUID0000001",
                                                     excludingEntry: nil)
        #expect(claims.map(\.entryID) == [earlier, later])
    }

    /// Review focus 4. A receipt the user took off a claim, or a claim they deleted, no
    /// longer supports anything — warning about it would be warning about nothing.
    @Test("removed documents and deleted entries support nothing")
    func removedDocumentsSupportNothing() async throws {
        let store = try await StoreFixture.store()
        let kept = try await Self.entry(store)
        let documentID = try await store.attach(Self.receipt(hash: "h1"), toEntry: kept)
        try await store.softDeleteDocument(id: documentID)
        #expect(try await store.claimsSupported(byHash: "h1", orEInvoiceUUID: nil,
                                                excludingEntry: nil).isEmpty)

        let deleted = try await Self.entry(store, ringgit: 99)
        _ = try await store.attach(Self.receipt(hash: "h2", uuid: "UUID0000002"), toEntry: deleted)
        try await store.softDeleteEntry(id: deleted)
        #expect(try await store.claimsSupported(byHash: "h2", orEInvoiceUUID: "UUID0000002",
                                                excludingEntry: nil).isEmpty)
    }

    @Test("an empty hash matches nothing, even documents with an empty hash")
    func emptyHashMatchesNothing() async throws {
        let store = try await StoreFixture.store()
        let entryID = try await Self.entry(store)
        _ = try await store.attach(Self.receipt(hash: ""), toEntry: entryID)
        #expect(try await store.claimsSupported(byHash: "", orEInvoiceUUID: nil,
                                                excludingEntry: nil).isEmpty)
    }

    /// Cancelling a scan deletes the file it wrote unless something points at it. A
    /// soft-deleted document still does: undo would bring it back to a missing file.
    @Test("a file is referenced while any document row points at it, removed or not")
    func fileReferences() async throws {
        let store = try await StoreFixture.store()
        #expect(try await store.isFileReferenced(hash: "h1") == false)

        let entryID = try await Self.entry(store)
        let documentID = try await store.attach(Self.receipt(hash: "h1"), toEntry: entryID)
        #expect(try await store.isFileReferenced(hash: "h1"))

        try await store.softDeleteDocument(id: documentID)
        #expect(try await store.isFileReferenced(hash: "h1"))
        #expect(try await store.isFileReferenced(hash: "") == false)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter DocumentReadingStoreTests`
Expected: FAIL — `extra arguments 'ocrText', 'eInvoiceUUID' in call` and `cannot find 'SupportedClaim' in scope`.

- [ ] **Step 3: Extend `DocumentDraft`**

In `Sources/TaxData/Store/TaxStore+Documents.swift`, add after `public var uti: String`:

```swift
    /// Every line the recogniser read, joined. What a later search or the assistant reads;
    /// nothing is derived from it here.
    public var ocrText: String?
    /// The MyInvois document UUID from the receipt's QR. A dedupe key and a badge — it
    /// never changes `kind`, because which document a relief accepts is the rulebook's
    /// call, not the QR's.
    public var eInvoiceUUID: String?
```

Extend the initialiser's parameter list after `uti: String = "public.jpeg"` with:

```swift
                ocrText: String? = nil,
                eInvoiceUUID: String? = nil) {
```

(replacing the old `uti: String = "public.jpeg") {` line with `uti: String = "public.jpeg",`), and at the end of its body:

```swift
        self.ocrText = ocrText
        self.eInvoiceUUID = eInvoiceUUID
```

- [ ] **Step 4: Write both fields in `attach`, dedupe on the e-invoice too, and read them back**

Replace the dedupe block in `attach(_:toEntry:)`:

```swift
        let hash = draft.contentHash
        if !hash.isEmpty,
           let existing = (entry.documents ?? [])
               .first(where: { $0.isLive && $0.file?.contentHash == hash }) {
            return existing.id
        }
```

with:

```swift
        // The same photo twice, or the same e-invoice twice as two different files — a
        // PDF downloaded from the portal and a photo of the printout share a UUID and
        // nothing else.
        let hash = draft.contentHash
        let uuid = draft.eInvoiceUUID
        if let existing = (entry.documents ?? []).first(where: { document in
            document.isLive
                && ((!hash.isEmpty && document.file?.contentHash == hash)
                    || (uuid != nil && document.eInvoiceUUID == uuid))
        }) {
            return existing.id
        }
```

After `document.thumbnail = draft.thumbnail`, add:

```swift
        document.ocrText = draft.ocrText
        document.eInvoiceUUID = draft.eInvoiceUUID
```

In `documentDrafts(forEntry:)`, extend the `DocumentDraft(...)` call's last argument:

```swift
                              uti: document.file?.uti ?? "public.data",
                              ocrText: document.ocrText,
                              eInvoiceUUID: document.eInvoiceUUID)
```

- [ ] **Step 5: Add the two queries**

Add inside `extension TaxStore`, after `restoreDocument(id:)`:

```swift
    /// The other claims this file or e-invoice already supports — what the duplicate
    /// warning prints. Spec §5: warned about, never blocked, because one bill can
    /// honestly split across two reliefs.
    ///
    /// Only a live document on a live, unmerged entry counts. A receipt the user took off
    /// a claim supports nothing, and warning about it would be warning about nothing.
    public func claimsSupported(byHash hash: String,
                                orEInvoiceUUID uuid: String?,
                                excludingEntry excluded: UUID?) throws -> [SupportedClaim] {
        var documents: [Document] = []
        if !hash.isEmpty {
            documents += try modelContext.fetch(FetchDescriptor<DocumentFile>(
                predicate: #Predicate { $0.contentHash == hash }))
                .compactMap(\.document)
        }
        if uuid != nil {
            // Optional to optional, so the predicate macro compares like with like.
            let match: String? = uuid
            documents += try modelContext.fetch(FetchDescriptor<Document>(
                predicate: #Predicate { $0.eInvoiceUUID == match }))
        }

        var seen: Set<UUID> = []
        return documents
            .filter(\.isLive)
            .flatMap { $0.entries ?? [] }
            .filter { $0.isLive && $0.mergedInto == nil && $0.id != excluded }
            .filter { seen.insert($0.id).inserted }
            .map { SupportedClaim(entryID: $0.id, code: $0.reliefCode,
                                  amount: $0.amount, spentOn: $0.spentOn) }
            .sorted { lhs, rhs in
                switch (lhs.spentOn, rhs.spentOn) {
                case let (l?, r?) where l != r: l < r
                case (_?, nil): true
                case (nil, _?): false
                default: lhs.entryID.uuidString < rhs.entryID.uuidString
                }
            }
    }

    /// Whether any document row points at this file. Cancelling a scan deletes the file it
    /// wrote only when this is false.
    ///
    /// Soft-deleted rows count: `restoreDocument` would bring the row back, and a restored
    /// receipt whose file had been deleted underneath it is a thumbnail with nothing behind
    /// it. Deliberately stricter than "a live `DocumentFile`" (spec §5) for that reason.
    public func isFileReferenced(hash: String) throws -> Bool {
        guard !hash.isEmpty else { return false }
        var descriptor = FetchDescriptor<DocumentFile>(
            predicate: #Predicate { $0.contentHash == hash })
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }
```

And after `DocumentAttachmentError` at the end of the file:

```swift
/// Another claim a receipt already supports: what the duplicate warning prints, and
/// nothing more.
public struct SupportedClaim: Hashable, Sendable {
    public var entryID: UUID
    public var code: ReliefCode
    public var amount: Money
    public var spentOn: Date?

    public init(entryID: UUID, code: ReliefCode, amount: Money, spentOn: Date?) {
        self.entryID = entryID
        self.code = code
        self.amount = amount
        self.spentOn = spentOn
    }
}
```

- [ ] **Step 6: Run to see it pass**

Run: `swift test --filter DocumentReadingStoreTests`
Expected: PASS, 9 tests.

Then: `swift test --filter TaxDataTests`
Expected: PASS — the existing `DocumentAttachmentTests` and the golden/persisted tests are unaffected. No schema change: `Document.ocrText` and `eInvoiceUUID` already exist.

- [ ] **Step 7: Commit**

```bash
git add Sources/TaxData/Store/TaxStore+Documents.swift Tests/TaxDataTests/DocumentAttachmentTests.swift
git commit -m "feat(data): record a receipt's text and e-invoice ID, and find claims it already supports

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: A receipt starts the entry

**Files:**
- Modify: `Package.swift` (`TaxPresentationTests` depends on `TaxCapture` too)
- Modify: `Sources/TaxPresentation/EntryEditorViewModel.swift`
- Create: `Sources/TaxPresentation/EntryEditorViewModel+Receipt.swift`
- Test: `Tests/TaxPresentationTests/ReceiptEditorTests.swift`

**Interfaces:**
- Consumes: `ReceiptReading`, `NormalisedDocument`, `Reading`, `ReceiptDate.timeZone`, `ReceiptDate.noon` (Tasks 1, 2, 6, 8); `DocumentDraft.ocrText`/`eInvoiceUUID`, `SupportedClaim`, `TaxStore.claimsSupported(byHash:orEInvoiceUUID:excludingEntry:)`, `TaxStore.isFileReferenced(hash:)` (Task 9); `DocumentFileStore` (existing).
- Produces, on `EntryEditorViewModel`:
  - `let newEntryID: UUID` — the id a new entry is saved under, stable across retries.
  - `public enum ReceiptField: Hashable, Sendable { case amount, date, vendor }`
  - `public internal(set) var unconfirmed: Set<ReceiptField>`, `suggestedReliefs: [ReliefCode]`, `couldNotReadReceipt: Bool`, `isEInvoice: Bool`, `receiptDuplicateWarning: String?`, `attachFailed: Bool`
  - `public var hasPendingReceipt: Bool`, `public var pendingReceiptThumbnail: Data?`, `public var receiptYearMismatch: String?`
  - `public func prefill(from reading: ReceiptReading, files: DocumentFileStore) async -> Bool` — call **before** `load()`.
  - `public func confirm(_ field: ReceiptField)`
  - `public func discardPendingReceipt() async` — the Cancel path.
  - `save()` attaches the pending receipt after saving the entry; returns `false` with `attachFailed == true` when that step fails.
  - Internal, for Task 11: `func warnIfAlreadySupporting(hash:uuid:excluding:) async`, `func reliefName(_:)` (was private).

- [ ] **Step 1: Let the presentation tests import `TaxCapture`**

In `Package.swift`, change the `TaxPresentationTests` target's dependencies to:

```swift
            dependencies: ["TaxPresentation", "TaxCapture"],
```

- [ ] **Step 2: Write the failing tests**

`Tests/TaxPresentationTests/ReceiptEditorTests.swift`:

```swift
import Testing
import Foundation
import TaxKit
import TaxData
import TaxCapture
@testable import TaxPresentation

/// Receipt readings built by hand: the view model's job is what it does with a reading,
/// not how one is made, and Vision has no place in these tests.
@MainActor enum ReceiptFixture {

    static func files() throws -> DocumentFileStore {
        try DocumentFileStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "relio-receipts-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { ReceiptDate.noon(y, m, d)! }

    static func reading(bytes: String = "receipt-one",
                        total: Money? = Money(sen: 7_190), totalConfidence: Double = 0.95,
                        date: Date? = day(2025, 3, 7), dateConfidence: Double = 0.5,
                        vendor: String? = "MPH BOOKSTORES SDN BHD", vendorConfidence: Double = 0.6,
                        ocrText: String? = "MPH BOOKSTORES SDN BHD\nTOTAL RM 71.90",
                        eInvoiceUUID: String? = nil,
                        suggested: [ReliefCode] = [.lifestyle]) -> ReceiptReading {
        ReceiptReading(
            document: NormalisedDocument(data: Data(bytes.utf8), uti: "public.jpeg",
                                         fileExtension: "jpg", thumbnail: Data("thumb".utf8),
                                         pageImages: [], textSource: .pageImages),
            ocrText: ocrText,
            eInvoiceUUID: eInvoiceUUID,
            total: total.map { Reading(value: $0, confidence: totalConfidence, source: .label("TOTAL")) },
            date: date.map { Reading(value: $0, confidence: dateConfidence, source: .label("DATE")) },
            vendor: vendor.map { Reading(value: $0, confidence: vendorConfidence, source: .heuristic) },
            suggestedReliefs: suggested)
    }

    /// A new-entry editor, *not* loaded: prefill comes first.
    static func newEditor(_ store: TaxStore, year: Int = 2025) async -> EntryEditorViewModel {
        let context = PresentationFixture.context(store, year: year)
        await context.load()
        return EntryEditorViewModel(context: context, store: store, editing: nil)
    }

    static func fileExists(_ files: DocumentFileStore, bytes: String) -> Bool {
        let url = files.url(forHash: DocumentFileStore.hash(Data(bytes.utf8)), extension: "jpg")
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Scans, picks Lifestyle and saves — the whole scan-first flow.
    static func scanAndSave(_ store: TaxStore, files: DocumentFileStore,
                            reading: ReceiptReading = reading()) async throws -> EntryEditorViewModel {
        let model = await newEditor(store)
        #expect(await model.prefill(from: reading, files: files))
        await model.load()
        model.selectedCode = .lifestyle
        #expect(await model.save())
        return model
    }
}

@Suite("Entry editor: a receipt starts the entry") @MainActor struct ReceiptEditorTests {

    @Test("the fields are prefilled, the relief is left for the user, and the file waits")
    func prefillsTheFields() async throws {
        let store = try await PresentationFixture.store()
        let files = try ReceiptFixture.files()
        let model = await ReceiptFixture.newEditor(store)

        #expect(await model.prefill(from: ReceiptFixture.reading(), files: files))
        await model.load()

        #expect(model.amountText == "71.90")
        #expect(model.vendor == "MPH BOOKSTORES SDN BHD")
        #expect(model.spentOn == ReceiptFixture.day(2025, 3, 7))
        #expect(model.unconfirmed == [.date, .vendor], "the total was read at 0.95")
        #expect(model.selectedCode == nil, "candidates are offered, never chosen")
        #expect(model.suggestedReliefs == [.lifestyle])
        #expect(model.hasPendingReceipt)
        #expect(model.pendingReceiptThumbnail == Data("thumb".utf8))
        #expect(ReceiptFixture.fileExists(files, bytes: "receipt-one"))
        #expect(try await store.entryDrafts(forYear: 2025).isEmpty, "nothing saved yet")
    }

    @Test("editing a field, or confirming it, clears its unconfirmed mark")
    func editingClearsUnconfirmed() async throws {
        let store = try await PresentationFixture.store()
        let model = await ReceiptFixture.newEditor(store)
        _ = await model.prefill(from: ReceiptFixture.reading(), files: try ReceiptFixture.files())

        model.vendor = "MPH Mid Valley"
        #expect(model.unconfirmed == [.date])
        model.confirm(.date)
        #expect(model.unconfirmed.isEmpty)
    }

    @Test("what the receipt did not say stays blank, and a blank read is said so")
    func missingFieldsStayBlank() async throws {
        let store = try await PresentationFixture.store()
        let model = await ReceiptFixture.newEditor(store)
        let blank = ReceiptFixture.reading(total: nil, date: nil, vendor: nil, ocrText: nil,
                                           suggested: [])
        #expect(await model.prefill(from: blank, files: try ReceiptFixture.files()))
        #expect(model.amountText == "")
        #expect(model.spentOn == nil)
        #expect(model.vendor == "")
        #expect(model.unconfirmed.isEmpty)
        #expect(model.couldNotReadReceipt)
        #expect(model.hasPendingReceipt, "the file is still attached on save")
    }

    @Test("saving saves the entry, then attaches the receipt with what was read")
    func saveAttachesTheReceipt() async throws {
        let store = try await PresentationFixture.store()
        let model = try await ReceiptFixture.scanAndSave(store, files: try ReceiptFixture.files())

        let entry = try #require(try await store.entryDrafts(forYear: 2025).first)
        #expect(entry.id == model.newEntryID)
        #expect(entry.amount == Money(sen: 7_190))
        #expect(entry.needsDocument == false)
        let document = try #require(try await store.documentDrafts(forEntry: entry.id).first)
        #expect(document.kind == .officialReceipt)
        #expect(document.contentHash == DocumentFileStore.hash(Data("receipt-one".utf8)))
        #expect(document.ocrText == "MPH BOOKSTORES SDN BHD\nTOTAL RM 71.90")
        #expect(document.total == Money(sen: 7_190))
        #expect(model.hasPendingReceipt == false)
    }

    @Test("an e-invoice is badged and still attached as the kind the relief asks for")
    func eInvoiceKeepsTheRequiredKind() async throws {
        let store = try await PresentationFixture.store()
        let reading = ReceiptFixture.reading(eInvoiceUUID: "F9D425P6DS7D8IU")
        let model = try await ReceiptFixture.scanAndSave(store, files: try ReceiptFixture.files(),
                                                         reading: reading)
        #expect(model.isEInvoice)
        let document = try #require(try await store.documentDrafts(forEntry: model.newEntryID).first)
        #expect(document.kind == .officialReceipt)
        #expect(document.eInvoiceUUID == "F9D425P6DS7D8IU")
    }

    @Test("saving twice is one entry, not two")
    func savingTwiceIsOneEntry() async throws {
        let store = try await PresentationFixture.store()
        let model = try await ReceiptFixture.scanAndSave(store, files: try ReceiptFixture.files())
        model.note = "Books for the course"
        #expect(await model.save())
        #expect(try await store.entryDrafts(forYear: 2025).count == 1)
        #expect(try await store.documentDrafts(forEntry: model.newEntryID).count == 1)
    }

    @Test("cancelling deletes a file nothing else uses")
    func cancelDeletesAnUnusedFile() async throws {
        let store = try await PresentationFixture.store()
        let files = try ReceiptFixture.files()
        let model = await ReceiptFixture.newEditor(store)
        _ = await model.prefill(from: ReceiptFixture.reading(), files: files)

        await model.discardPendingReceipt()
        #expect(ReceiptFixture.fileExists(files, bytes: "receipt-one") == false)
        #expect(model.hasPendingReceipt == false)
    }

    /// Review focus 2. The file store is content-addressed: scanning a receipt already on
    /// a claim writes the *same* file. Deleting it on cancel would take the saved claim's
    /// receipt with it.
    @Test("cancelling keeps a file another claim already uses")
    func cancelKeepsAFileAnotherClaimUses() async throws {
        let store = try await PresentationFixture.store()
        let files = try ReceiptFixture.files()
        _ = try await ReceiptFixture.scanAndSave(store, files: files)

        let again = await ReceiptFixture.newEditor(store)
        _ = await again.prefill(from: ReceiptFixture.reading(), files: files)
        #expect(again.receiptDuplicateWarning
                == "This receipt already supports your RM 71.90 lifestyle claim from 7 Mar.")

        await again.discardPendingReceipt()
        #expect(ReceiptFixture.fileExists(files, bytes: "receipt-one"))
    }

    /// Review focus 3. The editor has no year field: a receipt from December 2024 scanned
    /// with YA 2025 open is saved into 2025 unless the user notices.
    @Test("a receipt from another year is flagged, and the flag follows the date")
    func receiptFromAnotherYearIsFlagged() async throws {
        let store = try await PresentationFixture.store()
        let model = await ReceiptFixture.newEditor(store)
        _ = await model.prefill(from: ReceiptFixture.reading(date: ReceiptFixture.day(2024, 12, 28)),
                                files: try ReceiptFixture.files())
        #expect(model.receiptYearMismatch
                == "This receipt is dated 2024. It will count towards YA 2025 — switch year first if that is wrong.")

        model.spentOn = ReceiptFixture.day(2025, 1, 2)
        #expect(model.receiptYearMismatch == nil)
    }

    @Test("an entry typed by hand is never flagged for its year")
    func noReceiptNoYearFlag() async throws {
        let store = try await PresentationFixture.store()
        let model = await ReceiptFixture.newEditor(store)
        model.spentOn = ReceiptFixture.day(2024, 12, 28)
        #expect(model.receiptYearMismatch == nil)
    }

    @Test("the file cannot be written: nothing is prefilled and the caller is told")
    func fileWriteFailureRefusesPrefill() async throws {
        let store = try await PresentationFixture.store()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relio-gone-\(UUID().uuidString)", directoryHint: .isDirectory)
        let files = try DocumentFileStore(directory: directory)
        try FileManager.default.removeItem(at: directory)

        let model = await ReceiptFixture.newEditor(store)
        #expect(await model.prefill(from: ReceiptFixture.reading(), files: files) == false)
        #expect(model.amountText == "")
        #expect(model.hasPendingReceipt == false)
    }

    @Test("an editor opened on a saved entry is not prefilled")
    func editingIsNotPrefilled() async throws {
        let store = try await PresentationFixture.store()
        let id = try await store.save(EntryDraft(year: 2025, code: .lifestyle,
                                                 amount: Money(ringgit: 300)))
        let context = PresentationFixture.context(store, year: 2025)
        await context.load()
        let model = EntryEditorViewModel(context: context, store: store, editing: id)
        #expect(await model.prefill(from: ReceiptFixture.reading(),
                                    files: try ReceiptFixture.files()) == false)
    }
}
```

- [ ] **Step 3: Run to see it fail**

Run: `swift test --filter ReceiptEditorTests`
Expected: FAIL — `value of type 'EntryEditorViewModel' has no member 'prefill(from:files:)'`.

- [ ] **Step 4: Open up the view model for its receipt extension, and give a new entry a stable id**

In `Sources/TaxPresentation/EntryEditorViewModel.swift`:

1. Make the three stored dependencies internal — `EntryEditorViewModel+Receipt.swift` is another file in the same module and `private` would hide them:

```swift
    let context: YearContext
    let store: TaxStore
    let editingID: UUID?
```

(replacing the three `private let` lines).

2. After `private var deletedID: UUID?`, add:

```swift
    /// The id a new entry is saved under — fixed when the editor opens, not at save time.
    ///
    /// When a scanned receipt's attach step fails after the entry saved, tapping Save
    /// again must update that entry and retry the attach, not create a second entry. A
    /// fresh `UUID()` in `save()` made every retry a duplicate.
    let newEntryID = UUID()
```

3. Change `private func reliefName(_ code: ReliefCode) -> String` to `func reliefName(_ code: ReliefCode) -> String`.

4. In the `amountText`, `vendor` and `spentOn` setters, after `duplicateWarning = nil`, add respectively:

```swift
            unconfirmed.remove(.amount)
```
```swift
            unconfirmed.remove(.vendor)
```
```swift
            unconfirmed.remove(.date)
```

5. After `public private(set) var availableDependents: [DependentOption] = []`, add the receipt state. It must live in the class body — an extension cannot add stored properties:

```swift
    // MARK: Receipt state — behaviour in EntryEditorViewModel+Receipt.swift

    /// Fields a receipt prefilled below `ReadingConfidence.confirmed`. Editor state only:
    /// saving the entry *is* the user having looked (spec §2), so nothing is persisted.
    public internal(set) var unconfirmed: Set<ReceiptField> = []
    /// Shown first in the relief picker. Never selected for the user.
    public internal(set) var suggestedReliefs: [ReliefCode] = []
    /// The receipt produced no text at all.
    public internal(set) var couldNotReadReceipt = false
    /// The receipt carried a MyInvois QR. A badge; the document kind is unchanged.
    public internal(set) var isEInvoice = false
    /// "This receipt already supports your RM 230.00 lifestyle claim from 3 Mar."
    public internal(set) var receiptDuplicateWarning: String?
    /// The entry saved but its receipt could not be attached. Save again to retry.
    public internal(set) var attachFailed = false
    /// A scanned receipt already written to the file store, waiting for Save.
    var pendingReceipt: PendingReceipt?
```

6. In `checkForDuplicate()`, change `for entry in existing where entry.id != editingID {` to:

```swift
        for entry in existing where entry.id != (editingID ?? newEntryID) {
```

(after a failed attach the new entry exists, and it must not warn about itself).

7. In `save()`, change `let draft = EntryDraft(id: editingID ?? UUID(),` to `let draft = EntryDraft(id: editingID ?? newEntryID,`, and replace:

```swift
        do {
            _ = try await store.save(draft)
        } catch {
            return false
        }
```

with:

```swift
        do {
            _ = try await store.save(draft)
        } catch {
            return false
        }
        // Spec §5: the entry first, then its receipt. If the attach fails the entry stays,
        // the file stays on disk, and Save again retries both — `newEntryID` makes the
        // second save an update.
        if pendingReceipt != nil, await !attachPendingReceipt(to: draft.id) {
            await context.reload()
            return false
        }
```

- [ ] **Step 5: Write the receipt extension**

`Sources/TaxPresentation/EntryEditorViewModel+Receipt.swift`:

```swift
import Foundation
import TaxKit
import TaxData
import TaxCapture

/// A field a receipt can prefill.
public enum ReceiptField: Hashable, Sendable {
    case amount
    case date
    case vendor
}

/// A scanned receipt's file, already in the store, and the document it will become.
struct PendingReceipt {
    var draft: DocumentDraft
    var fileExtension: String
    var files: DocumentFileStore
}

extension EntryEditorViewModel {

    public var hasPendingReceipt: Bool { pendingReceipt != nil }

    public var pendingReceiptThumbnail: Data? { pendingReceipt?.draft.thumbnail }

    /// Opens a new entry from a receipt: amount, date and vendor set, relief candidates
    /// ready, and the file written and waiting. Call before `load()`.
    ///
    /// - Returns: false when the file could not be written — the caller shows "Relio could
    ///   not save that file. Try again." — or when this editor is not a new entry.
    @discardableResult
    public func prefill(from reading: ReceiptReading, files: DocumentFileStore) async -> Bool {
        guard !isEditing, pendingReceipt == nil else { return false }
        let stored: DocumentFileStore.Stored
        do {
            stored = try files.write(reading.document.data,
                                     extension: reading.document.fileExtension)
        } catch {
            return false
        }

        if let total = reading.total { amountText = total.value.formattedForEditing() }
        if let date = reading.date { spentOn = date.value }
        if let read = reading.vendor { vendor = read.value }
        // After the assignments, because each setter clears its own field's mark.
        var unsure: Set<ReceiptField> = []
        if let total = reading.total, !total.isConfirmed { unsure.insert(.amount) }
        if let date = reading.date, !date.isConfirmed { unsure.insert(.date) }
        if let read = reading.vendor, !read.isConfirmed { unsure.insert(.vendor) }
        unconfirmed = unsure

        suggestedReliefs = reading.suggestedReliefs
        couldNotReadReceipt = reading.couldNotRead
        isEInvoice = reading.eInvoiceUUID != nil
        // The kind is decided at save, from the relief the user picks.
        pendingReceipt = PendingReceipt(
            draft: DocumentDraft(vendor: reading.vendor?.value ?? "",
                                 documentDate: reading.date?.value,
                                 total: reading.total?.value,
                                 thumbnail: reading.document.thumbnail,
                                 byteCount: stored.byteCount,
                                 contentHash: stored.contentHash,
                                 uti: reading.document.uti,
                                 ocrText: reading.ocrText,
                                 eInvoiceUUID: reading.eInvoiceUUID),
            fileExtension: reading.document.fileExtension,
            files: files)

        await warnIfAlreadySupporting(hash: stored.contentHash, uuid: reading.eInvoiceUUID,
                                      excluding: newEntryID)
        return true
    }

    public func confirm(_ field: ReceiptField) {
        unconfirmed.remove(field)
    }

    /// Cancel. Deletes the file this editor wrote unless a document row points at it —
    /// the store is content-addressed, so a receipt already on another claim is the same
    /// file. If the store cannot answer, the file stays: a stray file costs disk, a
    /// missing one loses a receipt.
    public func discardPendingReceipt() async {
        guard let pending = pendingReceipt else { return }
        pendingReceipt = nil
        let hash = pending.draft.contentHash
        guard let referenced = try? await store.isFileReferenced(hash: hash),
              !referenced else { return }
        try? pending.files.delete(hash: hash, extension: pending.fileExtension)
    }

    /// The editor has no year field, so a receipt from another year would be saved into
    /// the open one without a word. Only for a scanned receipt: a date typed by hand is
    /// the user's own choice.
    public var receiptYearMismatch: String? {
        guard pendingReceipt != nil, let spentOn else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ReceiptDate.timeZone
        let year = calendar.component(.year, from: spentOn)
        guard year != context.year else { return nil }
        return "This receipt is dated \(year). It will count towards YA \(context.year) — switch year first if that is wrong."
    }

    /// Attaches the waiting receipt to the entry just saved.
    func attachPendingReceipt(to entryID: UUID) async -> Bool {
        guard var pending = pendingReceipt else { return true }
        // The relief decides which document this counts as; a QR never does.
        pending.draft.kind = requiredDocumentKinds.first ?? .officialReceipt
        // What the receipt said, where it said it; what the user typed otherwise.
        if pending.draft.vendor.isEmpty {
            pending.draft.vendor = vendor.trimmingCharacters(in: .whitespaces)
        }
        if pending.draft.documentDate == nil { pending.draft.documentDate = spentOn }
        if pending.draft.total == nil { pending.draft.total = MoneyParsing.money(from: amountText) }
        do {
            _ = try await store.attach(pending.draft, toEntry: entryID)
        } catch {
            attachFailed = true
            return false
        }
        attachFailed = false
        pendingReceipt = nil
        return true
    }

    /// Spec §5: warned about, never blocked.
    func warnIfAlreadySupporting(hash: String, uuid: String?, excluding entryID: UUID) async {
        guard let claim = try? await store.claimsSupported(byHash: hash, orEInvoiceUUID: uuid,
                                                           excludingEntry: entryID).first
        else {
            receiptDuplicateWarning = nil
            return
        }
        var text = "This receipt already supports your \(claim.amount.formatted()) \(Self.inSentence(reliefName(claim.code))) claim"
        if let spentOn = claim.spentOn { text += " from \(Self.dayAndMonth(spentOn))" }
        receiptDuplicateWarning = text + "."
    }

    /// "Lifestyle" reads "lifestyle" mid-sentence; "SSPN net deposit" keeps its acronym.
    static func inSentence(_ name: String) -> String {
        let opening = name.prefix(2)
        guard opening.count == 2, !opening.allSatisfy(\.isUppercase) else { return name }
        return name.prefix(1).lowercased() + name.dropFirst()
    }

    /// "3 Mar", in Malaysian time whatever the device's zone.
    static func dayAndMonth(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: Locale(identifier: "en_GB"),
                                        calendar: Calendar(identifier: .gregorian),
                                        timeZone: ReceiptDate.timeZone)
            .day().month(.abbreviated))
    }
}
```

- [ ] **Step 6: Run to see it pass**

Run: `swift test --filter ReceiptEditorTests`
Expected: PASS, 12 tests.

Then: `swift test --filter TaxPresentationTests`
Expected: PASS — the existing editor tests are unaffected (a new entry still saves; `newEntryID` only replaces the `UUID()` it was given before).

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/TaxPresentation/EntryEditorViewModel.swift \
  Sources/TaxPresentation/EntryEditorViewModel+Receipt.swift \
  Tests/TaxPresentationTests/ReceiptEditorTests.swift
git commit -m "feat(editor): start an entry from a receipt, attached when it is saved

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Attaching a receipt to an existing entry reads it too

**Files:**
- Modify: `Sources/TaxPresentation/EntryEditorViewModel.swift` (remove `attachDocument`; add `receiptAmountOffer`)
- Modify: `Sources/TaxPresentation/EntryEditorViewModel+Receipt.swift`
- Modify: `Tests/TaxPresentationTests/EntryEditorViewModelTests.swift:741-797` (migrate three tests)
- Test: `Tests/TaxPresentationTests/ReceiptEditorTests.swift` (add a suite)

**Interfaces:**
- Consumes: Task 10's `ReceiptFixture`, `warnIfAlreadySupporting`, `receiptDuplicateWarning`.
- Produces:
  - `public enum AttachResult: Hashable, Sendable { case attached, couldNotSave, couldNotAttach }`
  - `public func attach(_ reading: ReceiptReading, files: DocumentFileStore) async -> AttachResult`
  - `public internal(set) var receiptAmountOffer: Money?`, `public var receiptAmountOfferText: String?`, `public func useReceiptAmount()`, `public func dismissReceiptAmountOffer()`
  - Removes `attachDocument(kind:contentHash:byteCount:uti:thumbnail:)`. Task 12 moves its one app caller to `attach(_:files:)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TaxPresentationTests/ReceiptEditorTests.swift`:

```swift
@Suite("Entry editor: attaching a receipt to a saved entry") @MainActor
struct ReceiptAttachTests {

    static func savedEditor(_ store: TaxStore, ringgit: Decimal = 300,
                            spentOn: Date? = nil) async throws -> EntryEditorViewModel {
        let id = try await store.save(EntryDraft(year: 2025, code: .lifestyle,
                                                 amount: Money(ringgit: ringgit),
                                                 vendor: "Kinokuniya", spentOn: spentOn))
        let context = PresentationFixture.context(store, year: 2025)
        await context.load()
        let model = EntryEditorViewModel(context: context, store: store, editing: id)
        await model.load()
        return model
    }

    @Test("the document records what the receipt says")
    func documentRecordsTheReading() async throws {
        let store = try await PresentationFixture.store()
        let model = try await Self.savedEditor(store)
        let result = await model.attach(ReceiptFixture.reading(eInvoiceUUID: "F9D425P6DS7D8IU"),
                                        files: try ReceiptFixture.files())
        #expect(result == .attached)
        let document = try #require(model.documents.first)
        #expect(document.vendor == "MPH BOOKSTORES SDN BHD")
        #expect(document.total == Money(sen: 7_190))
        #expect(document.documentDate == ReceiptFixture.day(2025, 3, 7))
        #expect(document.eInvoiceUUID == "F9D425P6DS7D8IU")
        #expect(document.kind == .officialReceipt)
    }

    @Test("a confident total that disagrees is offered, and applied only when taken")
    func offersADifferentConfidentTotal() async throws {
        let store = try await PresentationFixture.store()
        let model = try await Self.savedEditor(store)
        _ = await model.attach(ReceiptFixture.reading(total: Money(sen: 12_840)),
                               files: try ReceiptFixture.files())

        #expect(model.receiptAmountOfferText == "The receipt says RM 128.40. Use that?")
        #expect(model.amountText == "300.00", "offered, never injected")

        model.useReceiptAmount()
        #expect(model.amountText == "128.40")
        #expect(model.receiptAmountOfferText == nil)
        #expect(try await store.entryDrafts(forYear: 2025).first?.amount == Money(ringgit: 300),
                "the user still saves it")
    }

    @Test("no offer when the total is unsure, or already the amount",
          arguments: [(Money(sen: 12_840), 0.4), (Money(ringgit: 300), 0.95)])
    func noOffer(total: Money, confidence: Double) async throws {
        let store = try await PresentationFixture.store()
        let model = try await Self.savedEditor(store)
        _ = await model.attach(ReceiptFixture.reading(total: total, totalConfidence: confidence),
                               files: try ReceiptFixture.files())
        #expect(model.receiptAmountOfferText == nil)
    }

    @Test("typing the receipt's figure yourself retires the offer; dismissing does too")
    func offerRetires() async throws {
        let store = try await PresentationFixture.store()
        let model = try await Self.savedEditor(store)
        _ = await model.attach(ReceiptFixture.reading(total: Money(sen: 12_840)),
                               files: try ReceiptFixture.files())
        model.amountText = "128.4"
        #expect(model.receiptAmountOfferText == nil)
        model.amountText = "300"
        #expect(model.receiptAmountOfferText != nil)
        model.dismissReceiptAmountOffer()
        #expect(model.receiptAmountOfferText == nil)
    }

    @Test("a receipt already on another claim is attached, with a warning")
    func warnsWhenAnotherClaimUsesIt() async throws {
        let store = try await PresentationFixture.store()
        let files = try ReceiptFixture.files()
        let first = try await Self.savedEditor(store, ringgit: 230,
                                               spentOn: ReceiptFixture.day(2025, 3, 3))
        _ = await first.attach(ReceiptFixture.reading(), files: files)
        #expect(first.receiptDuplicateWarning == nil)

        let second = try await Self.savedEditor(store, ringgit: 50)
        #expect(await second.attach(ReceiptFixture.reading(), files: files) == .attached)
        #expect(second.receiptDuplicateWarning
                == "This receipt already supports your RM 230.00 lifestyle claim from 3 Mar.")
    }

    @Test("the file cannot be written: nothing is attached")
    func fileWriteFailure() async throws {
        let store = try await PresentationFixture.store()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relio-gone-\(UUID().uuidString)", directoryHint: .isDirectory)
        let files = try DocumentFileStore(directory: directory)
        try FileManager.default.removeItem(at: directory)

        let model = try await Self.savedEditor(store)
        #expect(await model.attach(ReceiptFixture.reading(), files: files) == .couldNotSave)
        #expect(model.documents.isEmpty)
    }
}
```

Then migrate the three tests in `EntryEditorDocumentTests` (`Tests/TaxPresentationTests/EntryEditorViewModelTests.swift`). Add `import TaxCapture` below `import TaxData` at the top of the file, and replace each `attachDocument` call:

In `newEntryCannotAttach`:

```swift
        let attached = await model.attach(ReceiptFixture.reading(),
                                          files: try ReceiptFixture.files())
        #expect(attached == .couldNotAttach)
```

In `attachingSatisfiesTheClaim`:

```swift
        let attached = await model.attach(ReceiptFixture.reading(),
                                          files: try ReceiptFixture.files())
        #expect(attached == .attached)
```

In `removingIsUndoable`:

```swift
        _ = await model.attach(ReceiptFixture.reading(), files: try ReceiptFixture.files())
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter "ReceiptAttachTests|EntryEditorDocumentTests"`
Expected: FAIL — `value of type 'EntryEditorViewModel' has no member 'attach(_:files:)'`.

- [ ] **Step 3: Remove the old attach, and add the offer's state**

In `Sources/TaxPresentation/EntryEditorViewModel.swift`, delete `attachDocument(kind:contentHash:byteCount:uti:thumbnail:)` and its doc comment (the block from `/// Attaches a file that the caller has already written to disk.` to the closing brace before `public func removeDocument`). Leave the misplaced `validationError` doc comment above it where it is. It belongs to a later property, and moving it is not this task.

After `var pendingReceipt: PendingReceipt?`, add:

```swift
    /// A confident receipt total that disagrees with the amount. Offered, never applied.
    public internal(set) var receiptAmountOffer: Money?
```

- [ ] **Step 4: Write the attach**

Add to `Sources/TaxPresentation/EntryEditorViewModel+Receipt.swift`, after `ReceiptField`:

```swift
public enum AttachResult: Hashable, Sendable {
    case attached
    /// The file could not be written. "Relio could not save that file. Try again."
    case couldNotSave
    /// No saved entry to attach to, or the store refused.
    /// "Relio could not attach that. Nothing was lost — try again."
    case couldNotAttach
}
```

And inside the extension:

```swift
    /// Spec §5, attaching to an existing entry: the same reading, recorded on the
    /// `Document`, and the receipt's total offered when it is confident and differs.
    public func attach(_ reading: ReceiptReading, files: DocumentFileStore) async -> AttachResult {
        guard let editingID else { return .couldNotAttach }
        let stored: DocumentFileStore.Stored
        do {
            stored = try files.write(reading.document.data,
                                     extension: reading.document.fileExtension)
        } catch {
            return .couldNotSave
        }

        let draft = DocumentDraft(kind: requiredDocumentKinds.first ?? .officialReceipt,
                                  vendor: reading.vendor?.value
                                      ?? vendor.trimmingCharacters(in: .whitespaces),
                                  documentDate: reading.date?.value ?? spentOn,
                                  total: reading.total?.value ?? MoneyParsing.money(from: amountText),
                                  thumbnail: reading.document.thumbnail,
                                  byteCount: stored.byteCount,
                                  contentHash: stored.contentHash,
                                  uti: reading.document.uti,
                                  ocrText: reading.ocrText,
                                  eInvoiceUUID: reading.eInvoiceUUID)
        // Asked before attaching, so this entry's own new document is not what it finds.
        await warnIfAlreadySupporting(hash: stored.contentHash, uuid: reading.eInvoiceUUID,
                                      excluding: editingID)
        do {
            _ = try await store.attach(draft, toEntry: editingID)
        } catch {
            if (try? await store.isFileReferenced(hash: stored.contentHash)) == false {
                try? files.delete(hash: stored.contentHash,
                                  extension: reading.document.fileExtension)
            }
            return .couldNotAttach
        }

        receiptAmountOffer = reading.total.flatMap { $0.isConfirmed ? $0.value : nil }
        await reloadDocuments()
        await context.reload()
        return .attached
    }

    /// "The receipt says RM 128.40. Use that?" — until the amount already says it.
    public var receiptAmountOfferText: String? {
        guard let offer = receiptAmountOffer,
              MoneyParsing.money(from: amountText) != offer else { return nil }
        return "The receipt says \(offer.formatted()). Use that?"
    }

    /// Sets the field. The user still saves.
    public func useReceiptAmount() {
        guard let offer = receiptAmountOffer else { return }
        amountText = offer.formattedForEditing()
        receiptAmountOffer = nil
    }

    public func dismissReceiptAmountOffer() {
        receiptAmountOffer = nil
    }
```

- [ ] **Step 5: Run to see it pass**

Run: `swift test --filter "ReceiptAttachTests|EntryEditorDocumentTests|ReceiptEditorTests"`
Expected: PASS.

Then the whole package: `swift test`
Expected: PASS. `./Scripts/typecheck-app.sh` **fails** at this point: `EntryEditorView` still calls `attachDocument`. Task 12 fixes it. Record the failure in the ledger and do not paper over it here.

- [ ] **Step 6: Commit**

```bash
git add Sources/TaxPresentation/EntryEditorViewModel.swift \
  Sources/TaxPresentation/EntryEditorViewModel+Receipt.swift \
  Tests/TaxPresentationTests/ReceiptEditorTests.swift \
  Tests/TaxPresentationTests/EntryEditorViewModelTests.swift
git commit -m "feat(editor): read a receipt attached to a saved entry, and offer its total

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: The app scans, reads and prefills

**Files:**
- Create: `App/TaxTracker/Capture/CapturePipeline.swift`
- Create: `App/TaxTracker/Capture/DocumentCameraView.swift`
- Create: `App/TaxTracker/Capture/ReceiptCaptureModifier.swift`
- Modify: `App/TaxTracker/Entries/EntryEditorView.swift`
- Modify: `App/TaxTracker/Entries/ReliefPickerView.swift`
- Modify: `App/TaxTracker/RootView.swift` (toolbars at ~352 and ~494, the DEBUG hooks at ~128–150 and `openDemoScreen`)
- Modify: `App/TaxTracker/Support/DemoHarness.swift`
- Modify: `App/TaxTracker/Info.plist`
- Modify: `Sources/TaxPresentation/EntryEditorViewModel+Receipt.swift` (one accessor)
- Modify: `Tests/TaxPresentationTests/ReceiptEditorTests.swift` (one test)
- Modify: `README.md`

**Interfaces:**
- Consumes: `DocumentPipeline.standard()`, `read(_:ruleSet:)`, `CaptureInput`, `SampleReceipt.jpeg(lines:qr:)` (Tasks 6, 8); everything Task 10 and 11 put on `EntryEditorViewModel`.
- Produces (app module only):
  - `enum ReceiptSource: Hashable { case camera, photo, file }`
  - `extension View { func receiptCapture(source: Binding<ReceiptSource?>, ruleSet: RuleSet?, onRead: @escaping @MainActor (ReceiptReading) async -> Void, onError: @escaping @MainActor (String) -> Void) -> some View }`
  - `struct ReceiptSourceMenu: View` — the toolbar's "Scan a receipt" menu.
  - `@MainActor enum CapturePipeline { static func read(_:ruleSet:) async -> CapturePipeline.Outcome }`
  - `EntryEditorViewModel.receiptRuleSet: RuleSet?` (TaxPresentation).
  - DEBUG launch arguments `-relio-scan`, `-relio-scan-einvoice`, and screen `scan-picker`.

The app target has no unit tests. The gates are `./Scripts/typecheck-app.sh` and screenshots of the real app on the simulator, run through the real pipeline. The one view-model addition is test-first.

- [ ] **Step 1: A failing test for the rule set the capture reads against**

The editor view has no `YearContext` (it is internal to the view model), and the pipeline needs the open year's rulebook to suggest reliefs. Append to the `ReceiptEditorTests` suite in `Tests/TaxPresentationTests/ReceiptEditorTests.swift`:

```swift
    @Test("a receipt is read against the open year's rulebook")
    func readsAgainstTheOpenYear() async throws {
        let store = try await PresentationFixture.store()
        let model = await ReceiptFixture.newEditor(store, year: 2024)
        #expect(model.receiptRuleSet?.yearOfAssessment == 2024)
    }
```

Run: `swift test --filter ReceiptEditorTests/readsAgainstTheOpenYear`
Expected: FAIL — `value of type 'EntryEditorViewModel' has no member 'receiptRuleSet'`.

- [ ] **Step 2: Add the accessor**

In `Sources/TaxPresentation/EntryEditorViewModel+Receipt.swift`, inside the extension, after `pendingReceiptThumbnail`:

```swift
    /// The open year's rulebook, which relief suggestions are drawn from.
    public var receiptRuleSet: RuleSet? { context.ruleSet }
```

Run: `swift test --filter ReceiptEditorTests`
Expected: PASS, 13 tests.

- [ ] **Step 3: Camera permission**

In `App/TaxTracker/Info.plist`, before `<key>RelioStorageMode</key>`, add:

```xml
    <!-- VisionKit's document camera. Without this key the app is killed on first scan. -->
    <key>NSCameraUsageDescription</key>
    <string>Relio uses the camera to scan receipts. The photo stays on this device.</string>
```

- [ ] **Step 4: The pipeline, once, for the app**

`App/TaxTracker/Capture/CapturePipeline.swift`:

```swift
import Foundation
import TaxKit
import TaxCapture

/// The one `DocumentPipeline` the app uses, and the copy for the one failure it throws.
@MainActor
enum CapturePipeline {

    enum Outcome {
        case read(ReceiptReading)
        /// Copy to show. The bytes could not be decoded at all; nothing was written.
        case failed(String)
    }

    /// Built once. The Vision requests and, where available, the on-device model are
    /// set up inside it, and there is no reason to pay for that per scan.
    private static let pipeline = DocumentPipeline.standard()

    static func read(_ input: CaptureInput, ruleSet: RuleSet?) async -> Outcome {
        do {
            return .read(try await pipeline.read(input, ruleSet: ruleSet))
        } catch {
            // Spec §6, first row: the existing strings, unchanged.
            if case .pdf = input { return .failed("That file could not be read. Try another.") }
            return .failed("That photo could not be read. Try another.")
        }
    }
}
```

- [ ] **Step 5: The document camera**

`App/TaxTracker/Capture/DocumentCameraView.swift`:

```swift
import SwiftUI
import VisionKit

/// VisionKit's document camera: edge detection, perspective correction and multi-page
/// capture, none of which Relio should rebuild.
struct DocumentCameraView: UIViewControllerRepresentable {

    enum Result {
        /// One upright JPEG per page, in order.
        case scanned([Data])
        case cancelled
        case failed
    }

    /// False on the simulator and on hardware without a camera. The menu hides the
    /// option rather than offering something that cannot open.
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    let onFinish: @MainActor (Result) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let onFinish: @MainActor (Result) -> Void

        init(onFinish: @escaping @MainActor (Result) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).compactMap {
                scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.9)
            }
            onFinish(pages.isEmpty ? .cancelled : .scanned(pages))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish(.cancelled)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: any Error) {
            onFinish(.failed)
        }
    }
}
```

- [ ] **Step 6: One modifier for all three sources**

`App/TaxTracker/Capture/ReceiptCaptureModifier.swift`:

```swift
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import TaxKit
import TaxCapture

/// Where a receipt comes from.
enum ReceiptSource: Hashable {
    case camera
    case photo
    case file
}

/// The camera, the photo library and Files, each producing a `CaptureInput`, all read by
/// the same pipeline. The editor's documents section and Home's scan button both use it,
/// so a receipt is read the same way whichever door it came in by.
struct ReceiptCaptureModifier: ViewModifier {

    @Binding var source: ReceiptSource?
    let ruleSet: RuleSet?
    let onRead: @MainActor (ReceiptReading) async -> Void
    let onError: @MainActor (String) -> Void

    @State private var pickedPhoto: PhotosPickerItem?
    @State private var isReading = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: isShowing(.camera)) {
                DocumentCameraView { result in
                    source = nil
                    switch result {
                    case .scanned(let pages): Task { await read(.scannedPages(pages)) }
                    case .cancelled: break
                    case .failed: onError("The camera stopped before the scan finished. Try again.")
                    }
                }
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: isShowing(.photo), selection: $pickedPhoto,
                          matching: .images)
            .fileImporter(isPresented: isShowing(.file),
                          allowedContentTypes: [.image, .pdf]) { result in
                Task { await importFile(result) }
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                Task { await importPhoto(item) }
            }
            .overlay {
                if isReading {
                    ProgressView("Reading the receipt…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .allowsHitTesting(!isReading)
    }

    /// `source` is the single piece of state; each presenter sees only its own case.
    private func isShowing(_ kind: ReceiptSource) -> Binding<Bool> {
        Binding(get: { source == kind },
                set: { if !$0, source == kind { source = nil } })
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            onError("That photo could not be read. Try another.")
            return
        }
        await read(.image(data))
    }

    /// The security-scoped URL has to be opened and closed around the read, or the bytes
    /// come back empty for anything outside the app's own container.
    private func importFile(_ result: Result<URL, any Error>) async {
        guard case .success(let url) = result else {
            onError("That file could not be opened. Try another.")
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            onError("That file could not be read. Try another.")
            return
        }
        let isPDF = UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true
        await read(isPDF ? .pdf(data) : .image(data))
    }

    private func read(_ input: CaptureInput) async {
        isReading = true
        defer { isReading = false }
        switch await CapturePipeline.read(input, ruleSet: ruleSet) {
        case .read(let reading): await onRead(reading)
        case .failed(let message): onError(message)
        }
    }
}

extension View {
    func receiptCapture(source: Binding<ReceiptSource?>,
                        ruleSet: RuleSet?,
                        onRead: @escaping @MainActor (ReceiptReading) async -> Void,
                        onError: @escaping @MainActor (String) -> Void) -> some View {
        modifier(ReceiptCaptureModifier(source: source, ruleSet: ruleSet,
                                        onRead: onRead, onError: onError))
    }
}

/// "Scan a receipt", beside "Add an entry". The camera is listed only where it can open.
struct ReceiptSourceMenu: View {

    @Binding var source: ReceiptSource?

    var body: some View {
        Menu {
            if DocumentCameraView.isSupported {
                Button { source = .camera } label: {
                    Label("Scan with the camera", systemImage: "doc.viewfinder")
                }
            }
            Button { source = .photo } label: {
                Label("Choose a photo", systemImage: "photo")
            }
            Button { source = .file } label: {
                Label("Choose a file", systemImage: "folder")
            }
        } label: {
            Image(systemName: "doc.viewfinder")
        }
        .accessibilityLabel("Scan a receipt")
    }
}
```

- [ ] **Step 7: Suggested reliefs first in the picker**

In `App/TaxTracker/Entries/ReliefPickerView.swift`:

1. After `let options: [ReliefOption]`, add:

```swift
    /// Read off the receipt. Shown first, never selected — the user still chooses.
    var suggested: [ReliefCode] = []
```

2. Replace `ForEach(matches) { option in` … its closing brace (the whole row builder) by moving the row into a function, and render two sections. The `List` body becomes:

```swift
        List {
            if !suggestedMatches.isEmpty {
                Section("Suggested from the receipt") {
                    ForEach(suggestedMatches) { row($0) }
                }
                Section("All reliefs") {
                    ForEach(matches) { row($0) }
                }
            } else {
                ForEach(matches) { row($0) }
            }
        }
```

and the old row content moves verbatim into:

```swift
    private func row(_ option: ReliefOption) -> some View {
        Button {
            selection = option.code
            dismiss()
        } label: {
            // (the existing HStack, unchanged)
        }
        .buttonStyle(.plain)
    }
```

(Move the existing `HStack(alignment: .firstTextBaseline, spacing: 12) { … }.contentShape(Rectangle())` into the label exactly as it is, comments included.)

3. After `matches`, add:

```swift
    /// In the suggester's order, and only those that are both offered here and matching
    /// the search. A suggestion the list cannot show is not shown.
    private var suggestedMatches: [ReliefOption] {
        suggested.compactMap { code in matches.first { $0.code == code } }
    }
```

A suggested relief appears in both sections on purpose. "All reliefs" stays complete and in its usual order, so someone who ignores the suggestions finds everything where it always was.

- [ ] **Step 8: The editor**

In `App/TaxTracker/Entries/EntryEditorView.swift`:

1. Imports: remove `import PhotosUI` and `import UniformTypeIdentifiers`; add `import TaxCapture`.

2. State: delete `pickedPhoto`, `isImportingFile` and `attachingKind` (with its comment). The kind is now the view model's decision, from the rulebook. Add:

```swift
    /// Which picker, if any, is open. See `ReceiptCaptureModifier`.
    @State private var captureSource: ReceiptSource?
```

3. At the top of the `Form`, after the `readOnlyReason` section, add:

```swift
            if model.hasPendingReceipt {
                receiptSection
            }
```

4. The Amount row's label shows the unconfirmed mark:

```swift
                LabeledContent {
                    TextField("0.00", text: $model.amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                } label: {
                    HStack(spacing: 6) {
                        Text("Amount")
                        unconfirmedMark(.amount)
                    }
                }
```

5. The vendor field and the date picker get the same mark:

```swift
                HStack {
                    TextField("Vendor", text: $model.vendor)
                    unconfirmedMark(.vendor)
                }
```

```swift
                    DatePicker(selection: Binding(get: { model.spentOn ?? Date() },
                                                  set: { model.spentOn = $0 }),
                               displayedComponents: .date) {
                        HStack(spacing: 6) {
                            Text("Spent on")
                            unconfirmedMark(.date)
                        }
                    }
```

6. The relief picker destination passes the suggestions:

```swift
                ReliefPickerView(options: model.availableCodes,
                                 suggested: model.suggestedReliefs,
                                 selection: $model.selectedCode)
```

7. Cancel discards a pending receipt's file. Swipe-to-dismiss is disabled while one is waiting, because it would bypass that and leave an orphaned file:

```swift
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            Task {
                                await model.discardPendingReceipt()
                                dismiss()
                            }
                        }
                    }
```

and, after `.navigationBarTitleDisplayMode(.inline)`:

```swift
            .interactiveDismissDisabled(model.hasPendingReceipt)
```

8. Save: when the attach step failed the entry *did* save, so Home is told, and the editor stays open to retry:

```swift
                    Button("Save") {
                        Task {
                            if await model.save() {
                                onSaved()
                                dismiss()
                            } else if model.attachFailed {
                                onSaved()
                            }
                        }
                    }
```

9. The DEBUG hook in `.task` also opens the picker for the scan screenshot:

```swift
                if ["relief-picker", "scan-picker"].contains(DemoHarness.screen) { isPickingRelief = true }
```

10. Replace `.onChange(of: pickedPhoto) { … }` and `.fileImporter(…) { … }` with:

```swift
            .receiptCapture(source: $captureSource,
                            ruleSet: model.receiptRuleSet,
                            onRead: { reading in await attach(reading) },
                            onError: { attachError = $0 })
```

11. Delete `attach(from item:)`, `attach(from result:)`, `store(_:extension:uti:)` and `thumbnail(from:)`. Thumbnails are `ImageNormaliser`'s job now (spec §3). Add in their place:

```swift
    /// Attaches a read receipt to this saved entry. The view model writes the file,
    /// records what was read, and decides the document kind from the relief.
    private func attach(_ reading: ReceiptReading) async {
        attachError = nil
        guard let files = try? DocumentFileStore() else {
            attachError = "Relio could not save that file. Try again."
            return
        }
        switch await model.attach(reading, files: files) {
        case .attached:
            onSaved()
        case .couldNotSave:
            attachError = "Relio could not save that file. Try again."
        case .couldNotAttach:
            attachError = "Relio could not attach that. Nothing was lost — try again."
        }
    }

    /// A small orange mark on a field the receipt filled in without confidence. Tapping it
    /// confirms the value; editing the field clears it too.
    @ViewBuilder
    private func unconfirmedMark(_ field: ReceiptField) -> some View {
        if model.unconfirmed.contains(field) {
            Button {
                model.confirm(field)
            } label: {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
            }
            // Borderless, or the whole Form row becomes the button.
            .buttonStyle(.borderless)
            .accessibilityLabel("Read from the receipt, not confirmed")
            .accessibilityHint("Confirms the value")
        }
    }

    /// The scanned receipt waiting for Save, and everything the reading has to say.
    private var receiptSection: some View {
        Section {
            HStack(spacing: 12) {
                documentThumbnail(model.pendingReceiptThumbnail)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Receipt")
                    if model.isEInvoice {
                        Label("MyInvois e-invoice", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    Text("Attached when you save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if model.couldNotReadReceipt {
                Text("Relio couldn't read this receipt — fill it in below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let mismatch = model.receiptYearMismatch {
                Label(mismatch, systemImage: "calendar.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let warning = model.receiptDuplicateWarning {
                Label(warning, systemImage: "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if model.attachFailed {
                Label("Relio could not attach that. Nothing was lost — try again.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } footer: {
            if !model.unconfirmed.isEmpty {
                Text("Relio was not sure of the marked fields. Check them, or tap the mark to confirm.")
            }
        }
    }

    /// 40-point thumbnail, or a document glyph when there is none to show.
    @ViewBuilder
    private func documentThumbnail(_ data: Data?) -> some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "doc")
                .frame(width: 40, height: 40)
                .foregroundStyle(.secondary)
        }
    }
```

12. In `documentsSection`, replace the thumbnail `if … else …` inside the `ForEach` row with `documentThumbnail(document.thumbnail)`. Replace the `PhotosPicker` and "Attach a file" button with:

```swift
            if let offer = model.receiptAmountOfferText {
                VStack(alignment: .leading, spacing: 8) {
                    Text(offer)
                    // Side by side where they fit, stacked at the largest text sizes.
                    ViewThatFits {
                        HStack(spacing: 16) { offerButtons }
                        VStack(alignment: .leading, spacing: 8) { offerButtons }
                    }
                    .buttonStyle(.borderless)
                }
            }

            if !model.isReadOnly {
                if DocumentCameraView.isSupported {
                    Button { captureSource = .camera } label: {
                        Label("Scan a receipt", systemImage: "doc.viewfinder")
                    }
                }
                Button { captureSource = .photo } label: {
                    Label("Attach a photo", systemImage: "photo")
                }
                Button { captureSource = .file } label: {
                    Label("Attach a file", systemImage: "folder")
                }
            }
```

and add:

```swift
    /// Offer, never inject (spec §5): the field changes, and the user still saves.
    @ViewBuilder
    private var offerButtons: some View {
        Button("Use it") { model.useReceiptAmount() }
        Button("Keep mine") { model.dismissReceiptAmountOffer() }
            .foregroundStyle(.secondary)
    }
```

13. In `documentsFooter`, after the `attachError` branch, add:

```swift
        } else if let warning = model.receiptDuplicateWarning {
            Label(warning, systemImage: "doc.on.doc")
                .foregroundStyle(.orange)
```

(Only a saved entry has a documents section. A pending receipt's warning shows in `receiptSection` instead, so the two never duplicate.)

- [ ] **Step 9: Home's scan button, and the scan-first route**

In `App/TaxTracker/RootView.swift`:

1. Imports: add `import TaxCapture`.

2. State, after `@State private var editingEntry: EntryEditorViewModel?`:

```swift
    /// Home's "Scan a receipt": which picker is open.
    @State private var captureSource: ReceiptSource?
    /// A receipt that could not be decoded or saved. Shown as an alert, since no editor
    /// is open yet to show it in.
    @State private var captureError: String?
```

3. In **both** toolbars (the iPad sidebar's at ~352 and Home's at ~494), add before the `plus` item:

```swift
                        ToolbarItem(placement: .primaryAction) {
                            ReceiptSourceMenu(source: $captureSource)
                        }
```

4. Next to **both** `.sheet(item: $editingEntry)` modifiers, add:

```swift
        .receiptCapture(source: $captureSource,
                        ruleSet: context.ruleSet,
                        onRead: { reading in await openScanned(reading) },
                        onError: { captureError = $0 })
        .alert(captureError ?? "",
               isPresented: Binding(get: { captureError != nil },
                                    set: { if !$0 { captureError = nil } })) {
            Button("OK", role: .cancel) {}
        }
```

5. After `prefilledEditor(for:)`, add:

```swift
    /// Scan first (spec §5): a new-entry editor holding what the receipt said, its file
    /// already written and waiting for Save.
    private func openScanned(_ reading: ReceiptReading) async {
        let model = EntryEditorViewModel(context: context, store: store, editing: nil)
        guard let files = try? DocumentFileStore(),
              await model.prefill(from: reading, files: files) else {
            captureError = "Relio could not save that file. Try again."
            return
        }
        editingEntry = model
    }
```

6. Replace the DEBUG `-relio-attach` block (the `if DemoHarness.wantsAttachment, … { … }` in `.task`) with one that reads the generated receipt through the real pipeline and the real view-model path:

```swift
            if DemoHarness.wantsAttachment,
               let entry = try? await store.entryDrafts(forYear: context.year).first,
               let data = SampleReceipt.jpeg(),
               case .read(let reading) = await CapturePipeline.read(.image(data),
                                                                    ruleSet: context.ruleSet),
               let files = try? DocumentFileStore() {
                let editor = EntryEditorViewModel(context: context, store: store,
                                                  editing: entry.id)
                await editor.load()
                _ = await editor.attach(reading, files: files)
                await home.refresh()
                await documents.refresh()
            }
```

and after `openDemoScreen()`, still inside `#if DEBUG`:

```swift
            // Scan first, through the same pipeline and `openScanned` a real scan takes.
            // Only the camera is skipped, which the simulator does not have.
            if DemoHarness.wantsScan,
               let data = SampleReceipt.jpeg(qr: DemoHarness.scanQR),
               case .read(let reading) = await CapturePipeline.read(.image(data),
                                                                    ruleSet: context.ruleSet) {
                await openScanned(reading)
            }
```

7. In `openDemoScreen()`, add a case before `default:`:

```swift
        case "scan-picker":
            break   // `-relio-scan` opens the editor; the editor opens its picker.
```

- [ ] **Step 10: The harness**

In `App/TaxTracker/Support/DemoHarness.swift`:

1. Add `import TaxCapture`.
2. Replace the `wantsAttachment` doc comment's last paragraph and delete `sampleReceiptData()` (and its doc comment). `SampleReceipt` in `TaxCapture` replaces it: a real receipt with real text, where the old grey bars were only something to hash. The comment on `wantsAttachment` becomes:

```swift
    /// Attach a generated receipt to the first seeded entry on launch, read through the
    /// real pipeline and `EntryEditorViewModel.attach(_:files:)`.
    ///
    /// The picker itself needs a tap and cannot be driven here, but everything behind it
    /// can: normalising, OCR, the file store, `TaxStore.attach`, the requirement
    /// re-derived, and the row rendered with its thumbnail.
```

3. After `wantsAttachment`, add:

```swift
    /// Open a new-entry editor prefilled from a generated receipt, as `-relio-scan`, or
    /// `-relio-scan-einvoice` for one that carries a MyInvois QR.
    static var wantsScan: Bool {
        arguments.contains("-relio-scan") || arguments.contains("-relio-scan-einvoice")
    }

    /// The QR the generated receipt carries, if any. LHDN's own example document ID.
    static var scanQR: String? {
        arguments.contains("-relio-scan-einvoice")
            ? "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4T7W0"
            : nil
    }
```

- [ ] **Step 11: Type-check**

Run: `./Scripts/typecheck-app.sh`
Expected: `Type-check succeeded (N files).`, with N three more than before this task. This also clears the failure Task 11 recorded. If `@preconcurrency` on the camera delegate conformance produces an "has no effect" warning, the protocol is already main-actor. Remove the attribute and re-run.

Then: `swift test`
Expected: PASS.

- [ ] **Step 12: Look at it**

Run each and read every screenshot with the Read tool:

```bash
D="Relio Test Phone"
./Scripts/run-app.sh "$TMPDIR/scan.png"          -- -relio-demo -relio-scan
./Scripts/run-app.sh "$TMPDIR/scan-einvoice.png" -- -relio-demo -relio-scan-einvoice
./Scripts/run-app.sh "$TMPDIR/scan-picker.png"   -- -relio-demo -relio-scan -relio-screen scan-picker
./Scripts/run-app.sh "$TMPDIR/scan-2024.png"     -- -relio-demo -relio-year 2024 -relio-scan
./Scripts/run-app.sh "$TMPDIR/attached.png"      -- -relio-demo -relio-attach -relio-screen entry-existing
xcrun simctl ui "$D" content_size accessibility-extra-extra-extra-large
./Scripts/run-app.sh "$TMPDIR/scan-ax5.png"      -- -relio-demo -relio-scan-einvoice
xcrun simctl ui "$D" appearance dark
./Scripts/run-app.sh "$TMPDIR/scan-ax5-dark.png" -- -relio-demo -relio-scan-einvoice
xcrun simctl ui "$D" content_size large
xcrun simctl ui "$D" appearance light
```

Check each one and write down what was seen, not "looks correct":

- `scan.png`: "New entry" sheet. Amount 71.90 with no mark (read at high confidence). Spent on 7 Mar 2025 with an orange mark (07/03 is ambiguous). Vendor "MPH BOOKSTORES SDN BHD". Relief "Choose…". Receipt row with a real thumbnail and "Attached when you save.". The footer names the marked fields.
- `scan-einvoice.png`: as above, plus "MyInvois e-invoice" under "Receipt".
- `scan-picker.png`: "Suggested from the receipt" with Lifestyle, above "All reliefs".
- `scan-2024.png`: the year-mismatch line, "This receipt is dated 2025. It will count towards YA 2024 — switch year first if that is wrong."
- `attached.png`: the first seeded entry's documents section with one row, a thumbnail of the generated receipt, and no amount offer (a fresh editor has none).
- `scan-ax5.png` / `scan-ax5-dark.png`: the **right edge** of every row (the vendor field and its mark, the Amount label with its mark, the badge), the **bottom** of the receipt section and its footer (scroll is not available, so check that what is on screen is not clipped mid-line), and that no text is truncated to "…" where it should wrap.

If OCR returns nothing on the simulator, `scan.png` shows blank fields and "Relio couldn't read this receipt — fill it in below." Record that in the ledger as found. Do not change the harness to hide it. The unit and adapter tests already prove the reading on macOS; this step is about the screen.

- [ ] **Step 13: The manual**

In `README.md`:

1. In the "Current state" table, replace the two rows

```
| Attaching a receipt (photo or file), local file store | ✅ Built and read on the simulator |
| OCR, MyInvois e-invoices, iCloud Drive file sync | Not started — files are kept on one device |
```

with

```
| Scanning or attaching a receipt (camera, photo or file), read on device: total, date, vendor, relief suggestions | ✅ Built and read on the simulator; the document camera needs a real device |
| MyInvois e-invoices | QR read offline for the document ID and a badge; the verified figures behind the link are not fetched |
| iCloud Drive file sync, share extension | Not started — files are kept on one device |
```

2. In "Seeing a screen other than the first", after the `entry:LIFESTYLE:3000` example line in the code block, add:

```bash
./Scripts/run-app.sh shot.png -- -relio-demo -relio-scan          # a scanned receipt, prefilled
./Scripts/run-app.sh shot.png -- -relio-demo -relio-scan-einvoice # the same, with a MyInvois QR
```

and after the sentence listing `-relio-screen` names, add:

```
`-relio-scan` feeds a generated receipt through the real reading pipeline into a
prefilled new-entry editor (`-relio-scan-einvoice` adds a MyInvois QR; `-relio-screen
scan-picker` opens its relief picker), and `-relio-attach` attaches the same receipt to
the first seeded entry. Only the camera and the system pickers are skipped.
```

3. Add a short section after "What TaxKit does" and its example, before "Running the tests":

```markdown
## Reading receipts

A receipt starts an entry. **Scan a receipt** (beside **+**) opens the document camera,
Photos or Files. Relio reads the total, date and vendor, and suggests up to three reliefs,
but never picks one. Fields it was unsure of carry an orange mark until you edit or
confirm them. Nothing is saved until you tap Save, and the receipt is attached then.

- **All on the device.** Apple's Vision reads the text, and a fixed set of rules picks out the
  figures. Where Apple Intelligence is available, the on-device model may choose between
  two conflicting totals or fill in a missing vendor. Anything it says that is not in the
  receipt's own text is thrown away, and whatever it supplies is always marked unconfirmed.
  There is no network call.
- **MyInvois e-invoices.** The QR is read for its document ID, which badges the receipt
  and catches the same e-invoice attached twice. The figures behind the link are not
  fetched, since that would mean a network call to LHDN.
- **Attaching to a saved entry** reads the receipt too. If its total is certain and
  differs from the entry, Relio offers it ("The receipt says RM 128.40. Use that?") and
  leaves the choice to you.
- **The same receipt on two claims** is warned about, not blocked. One bill can
  legitimately split across two reliefs.
- Photos are resized and stripped of their metadata, GPS included, before they are
  stored.
```

- [ ] **Step 14: Commit**

```bash
git add App/TaxTracker/Capture/CapturePipeline.swift \
  App/TaxTracker/Capture/DocumentCameraView.swift \
  App/TaxTracker/Capture/ReceiptCaptureModifier.swift \
  App/TaxTracker/Entries/EntryEditorView.swift App/TaxTracker/Entries/ReliefPickerView.swift \
  App/TaxTracker/RootView.swift App/TaxTracker/Support/DemoHarness.swift \
  App/TaxTracker/Info.plist \
  Sources/TaxPresentation/EntryEditorViewModel+Receipt.swift \
  Tests/TaxPresentationTests/ReceiptEditorTests.swift README.md
git commit -m "feat(app): scan a receipt into a prefilled entry, and read attached ones

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: The on-device model, fact-checked

**Files:**
- Create: `Sources/TaxCapture/Reading/ReceiptModel.swift`
- Create: `Sources/TaxCapture/Reading/FoundationModelsReceiptModel.swift`
- Modify: `Sources/TaxCapture/DocumentPipeline.swift`
- Test: `Tests/TaxCaptureTests/ReceiptModelTests.swift`
- Modify: `README.md` (only if Step 7 finds the section wrong)

**Interfaces:**
- Consumes: `ReceiptReading`, `Reading`, `ReadingConfidence.model` (0.65), `ReadingSource.model`, `RuleSet.allReliefs`, the Task 8 test stubs `StubText`, `StubBarcodes`, `StubPDFText`.
- Produces:
  - `public struct ReliefChoice: Hashable, Sendable { code: ReliefCode; name: String }`
  - `public struct ReceiptModelQuestion: Hashable, Sendable { ocrText: String; totalCandidates: [Money]; reliefs: [ReliefChoice]; var prompt: String }`
  - `public struct ReceiptModelAnswer: Hashable, Sendable { vendor: String?; totalCandidate: Int?; relief: String? }`
  - `public protocol ReceiptModel: Sendable { func answer(_ question: ReceiptModelQuestion) async throws -> ReceiptModelAnswer }`
  - `public enum ReceiptModelCheck { static func question(for:in:) -> ReceiptModelQuestion?; static func answer(from:to:within:) async -> ReceiptModelAnswer?; static func apply(_:to:question:) -> ReceiptReading }`
  - `public struct FoundationModelsReceiptModel: ReceiptModel { public init?() }` (`#if canImport(FoundationModels)`)
  - `DocumentPipeline.init(…, now:, model: (any ReceiptModel)? = nil, modelTimeout: Duration = .seconds(3))`

The real model is never called in tests (spec §7). `FoundationModelsReceiptModel` is a thin adapter over the checked protocol, and is verified by type-checking and by the app run in Step 7.

- [ ] **Step 1: Write the failing tests**

`Tests/TaxCaptureTests/ReceiptModelTests.swift`:

```swift
#if canImport(ImageIO) && canImport(CoreText)
import Testing
import Foundation
import TaxKit
@testable import TaxCapture

/// Answers whatever it was built with, and records that it was asked.
struct StubModel: ReceiptModel {
    enum Failure: Error { case refused }
    var reply = ReceiptModelAnswer(vendor: nil, totalCandidate: nil, relief: nil)
    var fails = false
    func answer(_ question: ReceiptModelQuestion) async throws -> ReceiptModelAnswer {
        if fails { throw Failure.refused }
        return reply
    }
}

/// Never answers, and ignores cancellation — the worst case the timeout must survive.
struct SilentModel: ReceiptModel {
    func answer(_ question: ReceiptModelQuestion) async throws -> ReceiptModelAnswer {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        return ReceiptModelAnswer(vendor: nil, totalCandidate: nil, relief: nil)
    }
}

@Suite("The on-device model, fact-checked") struct ReceiptModelTests {

    static let text = "KEDAI  BUKU aneka\nTOTAL 45.00\nTOTAL 54.00"

    static func question(candidates: [Money] = [Money(sen: 5_400), Money(sen: 4_500)])
        -> ReceiptModelQuestion {
        ReceiptModelQuestion(ocrText: text, totalCandidates: candidates,
                             reliefs: [ReliefChoice(code: .lifestyle, name: "Lifestyle"),
                                       ReliefChoice(code: .lifestyleSports, name: "Sports")])
    }

    /// A reading as the parser leaves a receipt with two disagreeing totals and a
    /// vendor it was not sure of.
    static func unsure() -> ReceiptReading {
        ReceiptReading(
            document: NormalisedDocument(data: Data(), uti: "public.jpeg", fileExtension: "jpg",
                                         thumbnail: nil, pageImages: [], textSource: .pageImages),
            ocrText: text,
            total: Reading(value: Money(sen: 5_400), confidence: 0.5, source: .label("TOTAL")),
            vendor: Reading(value: "KEDAI BUKU", confidence: 0.6, source: .heuristic),
            totalCandidates: [Money(sen: 5_400), Money(sen: 4_500)],
            suggestedReliefs: [.lifestyleSports])
    }

    static func apply(_ answer: ReceiptModelAnswer, to reading: ReceiptReading = unsure())
        -> ReceiptReading {
        ReceiptModelCheck.apply(answer, to: reading, question: question())
    }

    @Test("a vendor printed on the receipt is taken, at model confidence")
    func vendorInTextIsTaken() {
        let result = Self.apply(ReceiptModelAnswer(vendor: "Kedai Buku Aneka",
                                                   totalCandidate: nil, relief: nil))
        #expect(result.vendor == Reading(value: "Kedai Buku Aneka",
                                         confidence: ReadingConfidence.model, source: .model))
    }

    /// Spec success criterion 3's sibling for text: a name the model made up never
    /// reaches the editor.
    @Test("a vendor that is not on the receipt is discarded",
          arguments: ["Kinokuniya", "", "   "])
    func vendorNotInTextIsDiscarded(vendor: String) {
        let result = Self.apply(ReceiptModelAnswer(vendor: vendor, totalCandidate: nil, relief: nil))
        #expect(result.vendor?.value == "KEDAI BUKU")
    }

    @Test("a vendor the parser was sure of is kept")
    func confidentVendorIsKept() {
        var reading = Self.unsure()
        reading.vendor = Reading(value: "KEDAI BUKU", confidence: 0.9, source: .heuristic)
        let result = Self.apply(ReceiptModelAnswer(vendor: "Kedai Buku Aneka",
                                                   totalCandidate: nil, relief: nil), to: reading)
        #expect(result.vendor?.value == "KEDAI BUKU")
    }

    @Test("an in-range candidate chooses between disagreeing totals")
    func candidateChoosesTheTotal() {
        let result = Self.apply(ReceiptModelAnswer(vendor: nil, totalCandidate: 1, relief: nil))
        #expect(result.total == Reading(value: Money(sen: 4_500),
                                        confidence: ReadingConfidence.model, source: .model))
    }

    /// Spec success criterion 3. The model only ever names an index, so the only way it
    /// could introduce a number is an index that is not one; that is discarded.
    @Test("an out-of-range candidate is discarded", arguments: [-1, 2, 99])
    func outOfRangeCandidateIsDiscarded(index: Int) {
        let result = Self.apply(ReceiptModelAnswer(vendor: nil, totalCandidate: index, relief: nil))
        #expect(result.total?.value == Money(sen: 5_400))
        #expect(result.total?.source == .label("TOTAL"))
    }

    @Test("a total the parser was sure of is not second-guessed")
    func confidentTotalIsKept() {
        var reading = Self.unsure()
        reading.total = Reading(value: Money(sen: 5_400), confidence: 0.95, source: .label("TOTAL"))
        let result = Self.apply(ReceiptModelAnswer(vendor: nil, totalCandidate: 1, relief: nil),
                                to: reading)
        #expect(result.total?.value == Money(sen: 5_400))
    }

    @Test("a relief it was offered moves to the front; three at most")
    func offeredReliefLeads() {
        var reading = Self.unsure()
        reading.suggestedReliefs = [.lifestyleSports, .medicalSerious, .medicalCheckup]
        let result = Self.apply(ReceiptModelAnswer(vendor: nil, totalCandidate: nil,
                                                   relief: "LIFESTYLE"), to: reading)
        #expect(result.suggestedReliefs == [.lifestyle, .lifestyleSports, .medicalSerious])
    }

    @Test("a relief it was not offered is discarded", arguments: ["SSPN", "MADE_UP", ""])
    func unofferedReliefIsDiscarded(code: String) {
        let result = Self.apply(ReceiptModelAnswer(vendor: nil, totalCandidate: nil, relief: code))
        #expect(result.suggestedReliefs == [.lifestyleSports])
    }

    @Test("nothing the model supplies is ever confirmed")
    func modelNeverConfirms() {
        let result = Self.apply(ReceiptModelAnswer(vendor: "KEDAI BUKU ANEKA",
                                                   totalCandidate: 0, relief: nil))
        #expect(result.vendor?.isConfirmed == false)
        #expect(result.total?.isConfirmed == false)
    }

    @Test("a model that never answers is abandoned at the timeout")
    func silentModelTimesOut() async {
        let started = ContinuousClock.now
        let answer = await ReceiptModelCheck.answer(from: SilentModel(), to: Self.question(),
                                                    within: .milliseconds(100))
        #expect(answer == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("a model that throws gives no answer")
    func failingModelGivesNothing() async {
        #expect(await ReceiptModelCheck.answer(from: StubModel(fails: true), to: Self.question(),
                                               within: .seconds(1)) == nil)
    }

    @Test("no text, no question")
    func noTextNoQuestion() throws {
        var reading = Self.unsure()
        reading.ocrText = nil
        #expect(ReceiptModelCheck.question(for: reading,
                                           in: try BundledRuleSetLoader().ruleSet(for: 2025)) == nil)
    }

    @Test("the question offers only claimable reliefs, and numbers the candidates")
    func questionContents() throws {
        let rules = try BundledRuleSetLoader().ruleSet(for: 2025)
        let question = try #require(ReceiptModelCheck.question(for: Self.unsure(), in: rules))
        #expect(!question.reliefs.isEmpty)
        #expect(question.reliefs.allSatisfy { rules.relief(for: $0.code)?.automatic == false })
        #expect(question.prompt.contains("0: RM 54.00"))
        #expect(question.prompt.contains("1: RM 45.00"))
        #expect(question.prompt.contains("LIFESTYLE"))
    }

    // MARK: Through the pipeline

    static func pipeline(model: (any ReceiptModel)?) -> DocumentPipeline {
        DocumentPipeline(normaliser: ImageNormaliser(),
                         text: StubText(lines: ["KEDAI BUKU ANEKA", "TOTAL 45.00", "TOTAL 54.00"]),
                         pdfText: StubPDFText(), barcodes: StubBarcodes(),
                         now: { Date(timeIntervalSince1970: 1_750_000_000) },
                         model: model)
    }

    @Test("the pipeline applies a checked answer")
    func pipelineAppliesTheAnswer() async throws {
        let input = CaptureInput.image(try #require(SampleReceipt.jpeg()))
        let rules = try BundledRuleSetLoader().ruleSet(for: 2025)
        let plain = try await Self.pipeline(model: nil).read(input, ruleSet: rules)
        #expect(plain.total?.isConfirmed == false, "precondition: two totals disagree")
        #expect(plain.totalCandidates.count == 2)

        let helped = try await Self.pipeline(model: StubModel(reply: ReceiptModelAnswer(
            vendor: nil, totalCandidate: 1, relief: nil))).read(input, ruleSet: rules)
        #expect(helped.total?.value == plain.totalCandidates[1])
        #expect(helped.total?.source == .model)
    }

    @Test("a failing model leaves the parser's reading exactly as it was")
    func pipelineIgnoresAFailingModel() async throws {
        let input = CaptureInput.image(try #require(SampleReceipt.jpeg()))
        let rules = try BundledRuleSetLoader().ruleSet(for: 2025)
        let plain = try await Self.pipeline(model: nil).read(input, ruleSet: rules)
        let failed = try await Self.pipeline(model: StubModel(fails: true)).read(input, ruleSet: rules)
        #expect(failed == plain)
    }
}
#endif
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter ReceiptModelTests`
Expected: FAIL — `cannot find type 'ReceiptModel' in scope`.

- [ ] **Step 3: Write the protocol and the fact-check**

`Sources/TaxCapture/Reading/ReceiptModel.swift`:

```swift
import Foundation
import Synchronization
import TaxKit

/// A relief the model may name, with the name it goes by.
public struct ReliefChoice: Hashable, Sendable {
    public var code: ReliefCode
    public var name: String

    public init(code: ReliefCode, name: String) {
        self.code = code
        self.name = name
    }
}

/// Everything the model is shown. It chooses among these; it never supplies a number.
public struct ReceiptModelQuestion: Hashable, Sendable {
    public var ocrText: String
    /// Best first, as the parser ranked them. The model answers with an index.
    public var totalCandidates: [Money]
    public var reliefs: [ReliefChoice]

    public init(ocrText: String, totalCandidates: [Money], reliefs: [ReliefChoice]) {
        self.ocrText = ocrText
        self.totalCandidates = totalCandidates
        self.reliefs = reliefs
    }

    public var prompt: String {
        let candidates = totalCandidates.enumerated()
            .map { "\($0.offset): \($0.element.formatted())" }
            .joined(separator: "\n")
        let codes = reliefs.map { "\($0.code.rawValue): \($0.name)" }.joined(separator: "\n")
        return """
        Receipt text:
        \(ocrText)

        Total candidates:
        \(candidates.isEmpty ? "(none)" : candidates)

        Reliefs:
        \(codes)
        """
    }
}

/// What the model said, unchecked.
public struct ReceiptModelAnswer: Hashable, Sendable {
    public var vendor: String?
    public var totalCandidate: Int?
    public var relief: String?

    public init(vendor: String?, totalCandidate: Int?, relief: String?) {
        self.vendor = vendor
        self.totalCandidate = totalCandidate
        self.relief = relief
    }
}

/// An on-device language model. Optional, and never trusted: see `ReceiptModelCheck`.
public protocol ReceiptModel: Sendable {
    func answer(_ question: ReceiptModelQuestion) async throws -> ReceiptModelAnswer
}

/// Spec §4, "The on-device model": what it may be asked, how long it is waited for, and
/// which parts of its answer survive.
public enum ReceiptModelCheck {

    /// Nil when there is no text: there is nothing to ask about.
    public static func question(for reading: ReceiptReading,
                                in ruleSet: RuleSet) -> ReceiptModelQuestion? {
        guard let text = reading.ocrText else { return nil }
        // The same filter the suggester applies: an automatic relief is never logged.
        let reliefs = ruleSet.allReliefs
            .filter { !$0.automatic }
            .map { ReliefChoice(code: $0.code, name: $0.name) }
        return ReceiptModelQuestion(ocrText: text, totalCandidates: reading.totalCandidates,
                                    reliefs: reliefs)
    }

    /// The answer, or nil if the model threw or took longer than `timeout`.
    ///
    /// Returns at the timeout even if the model ignores cancellation. A task group would
    /// wait for its child, so this races the two with a continuation that only the first
    /// to finish may resume.
    public static func answer(from model: any ReceiptModel, to question: ReceiptModelQuestion,
                              within timeout: Duration) async -> ReceiptModelAnswer? {
        let once = Once()
        return await withCheckedContinuation { continuation in
            let work = Task {
                let answer = try? await model.answer(question)
                once.run { continuation.resume(returning: answer) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                work.cancel()
                once.run { continuation.resume(returning: nil) }
            }
        }
    }

    /// Keeps what passes a check and silently drops the rest. Everything kept is at
    /// `ReadingConfidence.model`, below confirmed, so it is always marked for the user.
    public static func apply(_ answer: ReceiptModelAnswer, to reading: ReceiptReading,
                             question: ReceiptModelQuestion) -> ReceiptReading {
        var result = reading

        if let index = answer.totalCandidate,
           question.totalCandidates.indices.contains(index),
           !(reading.total?.isConfirmed ?? false) {
            result.total = Reading(value: question.totalCandidates[index],
                                   confidence: ReadingConfidence.model, source: .model)
        }

        if let vendor = answer.vendor,
           !collapsed(vendor).isEmpty,
           collapsed(question.ocrText).contains(collapsed(vendor)),
           (reading.vendor?.confidence ?? 0) < ReadingConfidence.confirmed {
            result.vendor = Reading(value: vendor.trimmingCharacters(in: .whitespaces),
                                    confidence: ReadingConfidence.model, source: .model)
        }

        if let named = answer.relief,
           let choice = question.reliefs.first(where: { $0.code.rawValue == named }) {
            result.suggestedReliefs = Array(([choice.code]
                + reading.suggestedReliefs.filter { $0 != choice.code }).prefix(3))
        }

        return result
    }

    /// Upper-cased, with every run of whitespace — newlines included — one space.
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").uppercased()
    }
}

/// Runs its body once, whichever caller gets there first.
private final class Once: Sendable {
    private let done = Mutex(false)

    func run(_ body: () -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
```

- [ ] **Step 4: Put it in the pipeline**

In `Sources/TaxCapture/DocumentPipeline.swift`:

1. Add stored properties after `private let now: @Sendable () -> Date`:

```swift
    private let model: (any ReceiptModel)?
    private let modelTimeout: Duration
```

2. Extend the initialiser:

```swift
    public init(normaliser: any ImageNormalising,
                text: any TextReading,
                pdfText: any PDFTextReading,
                barcodes: any BarcodeReading,
                now: @escaping @Sendable () -> Date = { Date() },
                model: (any ReceiptModel)? = nil,
                modelTimeout: Duration = .seconds(3)) {
        self.normaliser = normaliser
        self.text = text
        self.pdfText = pdfText
        self.barcodes = barcodes
        self.now = now
        self.model = model
        self.modelTimeout = modelTimeout
    }
```

3. `standard()` passes the real model where the framework exists:

```swift
    public static func standard() -> DocumentPipeline {
        #if canImport(FoundationModels)
        let model: (any ReceiptModel)? = FoundationModelsReceiptModel()
        #else
        let model: (any ReceiptModel)? = nil
        #endif
        return DocumentPipeline(normaliser: ImageNormaliser(),
                                text: VisionTextReader(),
                                pdfText: PDFTextReader(ocr: VisionTextReader()),
                                barcodes: VisionBarcodeReader(),
                                model: model)
    }
```

4. At the end of `read`, replace `return ReceiptReading(…)` with:

```swift
        var reading = ReceiptReading(document: document,
                                     ocrText: ocrText,
                                     eInvoiceUUID: eInvoiceUUID,
                                     total: fields.total,
                                     date: fields.date,
                                     vendor: fields.vendor,
                                     totalCandidates: fields.totalCandidates,
                                     suggestedReliefs: suggestions,
                                     failures: failures)
        // Last, and optional: unavailable, refusing, slow or wrong, the parser's
        // reading stands and nothing is said.
        if let model, let ruleSet,
           let question = ReceiptModelCheck.question(for: reading, in: ruleSet),
           let answer = await ReceiptModelCheck.answer(from: model, to: question,
                                                       within: modelTimeout) {
            reading = ReceiptModelCheck.apply(answer, to: reading, question: question)
        }
        return reading
```

- [ ] **Step 5: The Foundation Models adapter**

`Sources/TaxCapture/Reading/FoundationModelsReceiptModel.swift`:

```swift
#if canImport(FoundationModels)
import FoundationModels

@Generable
struct GeneratedReceiptAnswer {
    @Guide(description: "Merchant name exactly as printed on the receipt, or null")
    var vendor: String?
    @Guide(description: "Index of the grand total among the numbered total candidates, or null")
    var totalCandidate: Int?
    @Guide(description: "Code of the best-matching relief among those listed, or null")
    var relief: String?
}

/// Apple's on-device model. Nil where it is not available — older hardware, Apple
/// Intelligence off, the model still downloading — and the pipeline then runs without it.
public struct FoundationModelsReceiptModel: ReceiptModel {

    static let instructions = """
        You read Malaysian shop receipts. Answer only from the receipt text you are given. \
        Choose the grand total by its index among the total candidates. Choose a relief \
        only from the codes listed. Use null for anything you are not sure of.
        """

    public init?() {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
    }

    public func answer(_ question: ReceiptModelQuestion) async throws -> ReceiptModelAnswer {
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(to: question.prompt,
                                                 generating: GeneratedReceiptAnswer.self)
        return ReceiptModelAnswer(vendor: response.content.vendor,
                                  totalCandidate: response.content.totalCandidate,
                                  relief: response.content.relief)
    }
}
#endif
```

- [ ] **Step 6: Run to see it pass**

Run: `swift test --filter "ReceiptModelTests|DocumentPipelineTests"`
Expected: PASS — the 11 pipeline tests unchanged (their pipelines pass no model), and every model test.

Then `swift test` (PASS) and `./Scripts/typecheck-app.sh` (succeeded). Also the watchOS build Task 7 ran, because `FoundationModels` must stay behind its `canImport` there:

Run: `swift build --target TaxCapture --triple arm64-apple-watchos26.0 -Xswiftc -sdk -Xswiftc "$(xcrun --sdk watchos --show-sdk-path)"`
Expected: build succeeds.

- [ ] **Step 7: See it on the simulator**

Run: `./Scripts/run-app.sh "$TMPDIR/scan-model.png" -- -relio-demo -relio-scan` and read the screenshot. The generated receipt parses with a confident total and a company-suffix vendor, so the model has nothing to change. The screen must match Task 12's `scan.png` field for field. Any difference means the model overrode a confident value, which the fact-check forbids. Stop and fix that before committing. Record whether the simulator reported the model as available (add `print` temporarily if needed, and remove it before committing), because the ledger should say whether the model ever ran.

Read the README's "Reading receipts" section from Task 12 against what was built. It already describes the model. If anything there is now wrong, fix it in this commit.

- [ ] **Step 8: Commit**

```bash
git add Sources/TaxCapture/Reading/ReceiptModel.swift \
  Sources/TaxCapture/Reading/FoundationModelsReceiptModel.swift \
  Sources/TaxCapture/DocumentPipeline.swift Tests/TaxCaptureTests/ReceiptModelTests.swift
git commit -m "feat(capture): let the on-device model choose among the parser's readings, fact-checked

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

(Add `README.md` to the `git add` only if Step 7 changed it.)

---

### Task 14: Close-out

**Files:**
- Create: `docs/superpowers/logs/2026-09-23-receipt-reading-execution-ledger.md`

- [ ] **Step 1: Every gate, from clean**

```bash
swift test 2>&1 | tail -5
./Scripts/typecheck-app.sh
git status --short
```

Expected: every test passes, the count printed. The type-check succeeds. `git status` is clean apart from the ledger about to be written. Record the test count before this plan (from `git stash`-free means: `git log` the commit before Task 1 and read the count from the previous ledger, or run `swift test` on that commit in a scratch worktree) and after.

- [ ] **Step 2: Walk the spec**

Open `docs/superpowers/specs/2026-09-23-receipt-reading-design.md` beside the code and, for each of §1's five success criteria and each row of §6's failure table, write the test (file and name) or screenshot that shows it. Any line without one is a gap: fix it with its own test-first commit, or name it in the ledger's "not done" list. Do not leave it unmentioned.

- [ ] **Step 3: Write the ledger**

`docs/superpowers/logs/2026-09-23-receipt-reading-execution-ledger.md`, in the shape of `docs/superpowers/logs/2026-08-25-income-timeline-execution-ledger.md`:

- Header: the plan and spec paths, the commit range (`git log --oneline <first>^..HEAD`), and the test counts before and after, measured.
- One section per task: what was built, and anything that differed from the plan and why. Include Task 11's intentional red type-check, and what Task 12 Step 12 and Task 13 Step 7 actually saw, OCR on the simulator included.
- The spec walk from Step 2, as a table.
- **Carried forward**, numbered on from the highest item number in the earlier ledgers (`grep -n "item [0-9]" docs/superpowers/logs/*.md`):
  - Scan one real MyInvois e-invoice to confirm the host and `/{uuid}/share/{longId}` shape before release (spec §2).
  - Whether LHDN accepts an e-invoice for every relief that requires an official receipt is a rulebook question. Until it is answered, the document kind never becomes `.eInvoice` (spec §4).
  - The document camera has never run: the simulator has none. It needs a real device.
  - The Foundation Models path runs only where Apple Intelligence is available. Say whether it ever ran here.
  - Documents attached before this change are not re-read (spec §8).
  - The iCloud Drive file store and the share extension (spec §8).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/logs/2026-09-23-receipt-reading-execution-ledger.md
git commit -m "docs: ledger for receipt reading

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

