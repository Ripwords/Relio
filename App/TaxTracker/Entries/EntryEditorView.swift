import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import TaxKit
import TaxData
import TaxPresentation

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
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var isImportingFile = false
    @State private var attachError: String?
    /// Which kind the next attachment will be recorded as. Defaults to what the relief
    /// asks for, because that is almost always what the user is holding.
    @State private var attachingKind: DocumentKind = .officialReceipt

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

                LabeledContent("Amount") {
                    TextField("0.00", text: $model.amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
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
                TextField("Vendor", text: $model.vendor)
                // A button that reveals the picker, not a toggle labelled "Has a date" —
                // the same shape the dependant editor uses, and better for the same
                // reason: it asks the user to do the thing they want rather than to
                // classify whether the thing is true of their receipt.
                //
                // The three-state care is unchanged. `spentOn` stays nil until the picker
                // is actually moved, so an entry with no date keeps having no date.
                if hasDate {
                    DatePicker("Spent on",
                               selection: Binding(get: { model.spentOn ?? Date() },
                                                  set: { model.spentOn = $0 }),
                               displayedComponents: .date)
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
            .toolbar {
                // The pushed copy already has a back button doing exactly this; only the
                // sheet, which has no way out otherwise, needs its own.
                if presentation == .sheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await model.save() {
                                onSaved()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
            .navigationDestination(isPresented: $isPickingRelief) {
                ReliefPickerView(options: model.availableCodes,
                                 selection: $model.selectedCode)
            }
            .task {
                await model.load()
                hasDate = model.spentOn != nil
                #if DEBUG
                if DemoHarness.screen == "relief-picker" { isPickingRelief = true }
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
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task { await attach(from: item) }
            }
            .fileImporter(isPresented: $isImportingFile,
                          allowedContentTypes: [.image, .pdf]) { result in
                Task { await attach(from: result) }
            }
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

    /// A photo from the library. Read as `Data`, written to the file store, then recorded.
    private func attach(from item: PhotosPickerItem) async {
        attachError = nil
        pickedPhoto = nil
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            attachError = "That photo could not be read. Try another."
            return
        }
        await store(data, extension: "jpg", uti: "public.jpeg")
    }

    /// A file from Files. The security-scoped URL has to be opened and closed around the
    /// read, or the bytes come back empty for anything outside the app's own container.
    private func attach(from result: Result<URL, any Error>) async {
        attachError = nil
        guard case .success(let url) = result else {
            attachError = "That file could not be opened. Try another."
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            attachError = "That file could not be read. Try another."
            return
        }
        let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
        let uti = UTType(filenameExtension: ext)?.identifier ?? "public.data"
        await store(data, extension: ext, uti: uti)
    }

    /// Writes the bytes, then records what they hash to.
    ///
    /// The thumbnail is the only part that would ever sync (spec §6), so it is made here
    /// and kept small rather than mirroring the full image.
    private func store(_ data: Data, extension ext: String, uti: String) async {
        do {
            let files = try DocumentFileStore()
            let stored = try files.write(data, extension: ext)
            let attached = await model.attachDocument(
                kind: attachingKind,
                contentHash: stored.contentHash,
                byteCount: stored.byteCount,
                uti: uti,
                thumbnail: Self.thumbnail(from: data))
            if !attached {
                attachError = "Relio could not attach that. Nothing was lost — try again."
            }
            onSaved()
        } catch {
            attachError = "Relio could not save that file. Try again."
        }
    }

    /// ~30 KB is what spec §6 budgets for the only image bytes that sync. A 256-point
    /// square is comfortably inside that as JPEG and is legible in a row.
    private static func thumbnail(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let side: CGFloat = 256
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.7)
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
                    if let data = document.thumbnail, let image = UIImage(data: data) {
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ReliefCopy.text(for: document.kind))
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

            if !model.isReadOnly {
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Label("Attach a photo", systemImage: "photo")
                }
                Button {
                    isImportingFile = true
                } label: {
                    Label("Attach a file", systemImage: "folder")
                }
            }
        } header: {
            Text("Documents")
        } footer: {
            documentsFooter
        }
    }

    @ViewBuilder
    private var documentsFooter: some View {
        if let attachError {
            Label(attachError, systemImage: "exclamationmark.triangle")
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
