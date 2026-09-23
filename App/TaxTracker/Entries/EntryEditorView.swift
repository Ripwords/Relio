import SwiftUI
import TaxKit
import TaxData
import TaxPresentation
import TaxCapture

/// How the editor is on screen.
///
/// The sheet arrives with no navigation bar of its own, so it has to bring one. The
/// pushed copy is already inside the stack it was pushed onto; wrapping there nests a
/// stack in a stack and renders two bars, and puts a "Cancel" button next to the back
/// button that already does the same job.
enum EntryEditorPresentation: Hashable {
    case sheet
    case pushed
}

struct EntryEditorView: View {

    /// `@State`, not a stored `let`. The pushed copy is rebuilt every time the view that
    /// declared the destination re-renders; the sheet copy is rebuilt every time the
    /// presenter re-renders. Either way a stored model would be silently replaced
    /// mid-edit by an empty one, discarding whatever the user had typed.
    @State private var model: EntryEditorViewModel
    @Environment(\.dismiss) private var dismiss
    let presentation: EntryEditorPresentation
    /// Home copies out of the shared evaluation rather than reading it through, so it has
    /// to be told a write happened. The delete path has always said so; the save path
    /// used to rely on Home being destroyed and rebuilt, which is the defect this wave
    /// removes.
    let onSaved: () -> Void
    let onDeleted: (EntryEditorViewModel) -> Void

    @State private var hasDate = false
    /// A button plus `navigationDestination(isPresented:)` rather than a NavigationLink,
    /// so a screenshot run can open the picker — there is no way to tap this simulator.
    @State private var isPickingRelief = false
    @State private var attachError: String?
    /// Which picker, if any, is open. See `ReceiptCaptureModifier`.
    @State private var captureSource: ReceiptSource?

    init(model: EntryEditorViewModel,
         presentation: EntryEditorPresentation,
         onSaved: @escaping () -> Void,
         onDeleted: @escaping (EntryEditorViewModel) -> Void) {
        _model = State(initialValue: model)
        self.presentation = presentation
        self.onSaved = onSaved
        self.onDeleted = onDeleted
    }

    @ViewBuilder
    var body: some View {
        switch presentation {
        case .sheet:
            NavigationStack { form }
        case .pushed:
            form
        }
    }

    private var form: some View {
        @Bindable var model = model
        return Form {
            if let reason = model.readOnlyReason {
                Section {
                    Label(reason, systemImage: "info.circle")
                        .font(.footnote)
                }
            }

            if model.hasPendingReceipt {
                receiptSection
            }

            Section {
                // A searchable list rather than a `Picker`. Two dozen reliefs with no way
                // to search is a lot of scrolling on the screen the app exists to make
                // quick, and a picker row can only show a name — which is not enough to
                // decide between "Lifestyle" and "Lifestyle — sports".
                Button {
                    isPickingRelief = true
                } label: {
                    LabeledContent("Relief") {
                        if let code = model.selectedCode {
                            Text(ReliefCopy.shortName(
                                for: code,
                                fullName: model.availableCodes
                                    .first { $0.code == code }?.name ?? code.rawValue))
                        } else {
                            Text("Choose…").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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

                // The cap, while there is still time to do something about it. Without
                // this the editor took RM 3,000 against a RM 2,500 relief without
                // comment, and the user found out — if ever — by noticing later that the
                // relief's "claimed" and "allowed" figures disagreed.
                if let guidance = model.capGuidance {
                    capNote(guidance)
                }

                if !model.admittedClaimants.isEmpty {
                    Picker("Claimed for", selection: $model.claimant) {
                        ForEach(model.admittedClaimants, id: \.self) { who in
                            Text(who.rawValue.capitalized).tag(who)
                        }
                    }
                }

                if model.allowsDependent, !model.availableDependents.isEmpty {
                    Picker("Which person", selection: $model.dependentID) {
                        Text("Not specified").tag(UUID?.none)
                        ForEach(model.availableDependents) { dependent in
                            Text(dependent.name).tag(UUID?.some(dependent.id))
                        }
                    }
                }
            }

            Section {
                HStack {
                    TextField("Vendor", text: $model.vendor)
                    unconfirmedMark(.vendor)
                }
                // A button that reveals the picker, not a toggle labelled "Has a date" —
                // the same shape the dependant editor uses, and better for the same
                // reason: it asks the user to do the thing they want rather than to
                // classify whether the thing is true of their receipt.
                //
                // The three-state care is unchanged. `spentOn` stays nil until the picker
                // is actually moved, so an entry with no date keeps having no date.
                if hasDate {
                    DatePicker(selection: Binding(get: { model.spentOn ?? Date() },
                                                  set: { model.spentOn = $0 }),
                               displayedComponents: .date) {
                        HStack(spacing: 6) {
                            Text("Spent on")
                            unconfirmedMark(.date)
                        }
                    }
                    Button("Remove the date") {
                        hasDate = false
                        model.spentOn = nil
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Button("Set the date spent") { hasDate = true }
                }
                TextField("Note", text: $model.note, axis: .vertical)
            }

            // Only for a saved entry: there is no identity to attach to until then, and
            // offering a picker that could not keep the file would be worse than not
            // offering one. The Docs tab is the route back here for exactly this.
            if model.isEditing {
                documentsSection
            }

            if let error = model.validationError, !model.amountText.isEmpty {
                Section { Text(error).foregroundStyle(.orange).font(.footnote) }
            } else if let warning = model.duplicateWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            if model.readOnlyReason == nil, model.canDelete {
                Section {
                    Button("Delete", role: .destructive) {
                        Task {
                            await model.delete()
                            onDeleted(model)
                            dismiss()
                        }
                    }
                }
            }
        }
            .navigationTitle(model.isEditing ? "Edit entry" : "New entry")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.hasPendingReceipt)
            .toolbar {
                // The pushed copy already has a back button doing exactly this; only the
                // sheet, which has no way out otherwise, needs its own.
                if presentation == .sheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            Task {
                                await model.discardPendingReceipt()
                                dismiss()
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
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
                    .disabled(!model.canSave)
                }
            }
            .navigationDestination(isPresented: $isPickingRelief) {
                ReliefPickerView(options: model.availableCodes,
                                 suggested: model.suggestedReliefs,
                                 selection: $model.selectedCode)
            }
            .task {
                await model.load()
                hasDate = model.spentOn != nil
                #if DEBUG
                if ["relief-picker", "scan-picker"].contains(DemoHarness.screen) { isPickingRelief = true }
                #endif
            }
            .onChange(of: hasDate) { _, isOn in
                if !isOn { model.spentOn = nil }
            }
            // Spec §6.5: catch the duplicate at entry time, before the sweep has to.
            // Every field that composes the dedupe key must re-check — leaving one out
            // (claimant, dependent, date) lets an edit to just that field silently drop
            // or miss a warning that still applies.
            .onChange(of: model.amountText) { Task { await model.checkForDuplicate() } }
            .onChange(of: model.vendor) { Task { await model.checkForDuplicate() } }
            .onChange(of: model.selectedCode) { Task { await model.checkForDuplicate() } }
            .onChange(of: model.claimant) { Task { await model.checkForDuplicate() } }
            .onChange(of: model.dependentID) { Task { await model.checkForDuplicate() } }
            .onChange(of: model.spentOn) { Task { await model.checkForDuplicate() } }
            .receiptCapture(source: $captureSource,
                            ruleSet: model.receiptRuleSet,
                            onRead: { reading in await attach(reading) },
                            onError: { attachError = $0 })
            // The claim's supporting document is a destructive thing to remove, and spec
            // §11.6 wants every one of those undoable.
            .overlay(alignment: .bottom) {
                if model.lastRemovedDocument != nil {
                    UndoToast(message: "Document removed",
                              undo: { await model.undoRemoveDocument() },
                              isPresented: Binding(
                                get: { model.lastRemovedDocument != nil },
                                set: { if !$0 { model.clearDocumentUndo() } }))
                        .padding(.bottom, 12)
                }
            }
    }

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

    /// The receipts and certificates supporting this claim.
    ///
    /// The whole document loop existed except this: Home's prompt, the Docs tab and the
    /// relief detail could all say a claim was short of a document, and nothing anywhere
    /// could attach one.
    @ViewBuilder
    private var documentsSection: some View {
        Section {
            ForEach(model.documents) { document in
                HStack(spacing: 12) {
                    documentThumbnail(document.thumbnail)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ReliefCopy.text(for: document.kind))
                        if document.isEInvoice {
                            Label("MyInvois e-invoice", systemImage: "checkmark.seal")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                        Text(document.byteCount.formatted(.byteCount(style: .file)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .swipeActions {
                    Button("Remove", role: .destructive) {
                        Task { await model.removeDocument(id: document.id) }
                    }
                }
            }

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
        } header: {
            Text("Documents")
        } footer: {
            documentsFooter
        }
    }

    /// Offer, never inject (spec §5): the field changes, and the user still saves.
    @ViewBuilder
    private var offerButtons: some View {
        Button("Use it") { model.useReceiptAmount() }
        Button("Keep mine") { model.dismissReceiptAmountOffer() }
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var documentsFooter: some View {
        if let attachError {
            Label(attachError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if let warning = model.receiptDuplicateWarning {
            Label(warning, systemImage: "doc.on.doc")
                .foregroundStyle(.orange)
        } else if model.documents.isEmpty, let needed = model.requiredDocumentKinds.first {
            // Names the one that would satisfy the claim rather than listing everything a
            // document could be.
            Text("LHDN asks for \(ReliefCopy.text(for: needed).lowercased()) with this claim. "
                 + "Kept on this device only.")
        } else {
            Text("Kept on this device only — Relio has no server.")
        }
    }

    /// Advice, not an error: secondary type while the amount fits, orange only once part
    /// of it would not count. Save stays enabled either way — LHDN caps what it allows,
    /// it does not stop anyone spending more, and an editor that refused the real figure
    /// would push the user to write down a number that is not what they spent.
    @ViewBuilder
    private func capNote(_ guidance: EntryEditorViewModel.CapGuidance) -> some View {
        // One `Text`, not an `HStack` of `MoneyText` and labels. A sentence built from
        // side-by-side views cannot wrap as a sentence: at this width the first attempt
        // broke into "RM 2,200.00 | of this will not count. | The cap is | RM 2,500.00"
        // with the figures orphaned from the words they belong to. The amounts still come
        // from the one formatter, the same way every accessibility label in the app does.
        if guidance.overBy > .zero {
            Label {
                Text("\(guidance.overBy.formatted()) of this will not count. "
                     + "The cap is \(guidance.cap.formatted()), and "
                     + "\(guidance.headroom.formatted()) of it is left.")
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .font(.footnote)
            .foregroundStyle(.orange)
        } else if let remaining = guidance.remainingAfter {
            // What the user will be on once they save, not the room before they did.
            Text(remaining > .zero
                 ? "\(remaining.formatted()) of this relief will be left after this."
                 : "This uses the rest of the relief.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text("\(guidance.headroom.formatted()) of this relief is still claimable.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
