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
