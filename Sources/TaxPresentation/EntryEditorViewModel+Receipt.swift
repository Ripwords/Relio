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

public enum AttachResult: Hashable, Sendable {
    case attached
    /// The file could not be written. "Relio could not save that file. Try again."
    case couldNotSave
    /// No saved entry to attach to, or the store refused.
    /// "Relio could not attach that. Nothing was lost — try again."
    case couldNotAttach
}

extension EntryEditorViewModel {

    public var hasPendingReceipt: Bool { pendingReceipt != nil }

    public var pendingReceiptThumbnail: Data? { pendingReceipt?.draft.thumbnail }

    /// The open year's rulebook, which relief suggestions are drawn from.
    public var receiptRuleSet: RuleSet? { context.ruleSet }

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
        let documentID: UUID
        do {
            documentID = try await store.attach(draft, toEntry: editingID)
        } catch {
            if (try? await store.isFileReferenced(hash: stored.contentHash)) == false {
                try? files.delete(hash: stored.contentHash,
                                  extension: reading.document.fileExtension)
            }
            return .couldNotAttach
        }

        // M9: the same e-invoice UUID, already on this entry as a different file, is
        // `store.attach` returning the *existing* document rather than storing this one —
        // the file just written above is then referenced by nothing, and would sit on disk
        // forever if left there.
        if let existing = try? await store.documentDrafts(forEntry: editingID)
            .first(where: { $0.id == documentID }),
           existing.contentHash != stored.contentHash,
           (try? await store.isFileReferenced(hash: stored.contentHash)) == false {
            try? files.delete(hash: stored.contentHash, extension: reading.document.fileExtension)
        }

        receiptAmountOffer = reading.total.flatMap { $0.isConfirmed ? $0.value : nil }
        attachedReceiptCouldNotRead = reading.couldNotRead
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

    /// Attaches the waiting receipt to the entry just saved.
    ///
    /// M9 does not apply here: the orphaned-file case needs a *second* e-invoice write to
    /// land on an entry that already carries the first one under a different hash, and
    /// `entryID` here is `newEntryID` — a fresh id this editor has never saved before, so
    /// `entry.documents` is always empty when `store.attach` below runs. There is nothing
    /// yet for the dedupe to fall back to.
    func attachPendingReceipt(to entryID: UUID) async -> Bool {
        // Mutates a local copy, not `pendingReceipt` itself: on failure `self.pendingReceipt`
        // is left exactly as it was, so a retry recomputes `kind`/`vendor`/etc. below from
        // whatever the form holds by then, not from what it held at the failed attempt.
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
