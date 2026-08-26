import SwiftUI
import TaxKit
import TaxPresentation

struct ReliefDetailView: View {

    /// `@State`, not a stored `let`: this screen is a navigation destination, so the view
    /// struct is rebuilt every time the view that declared the destination re-renders.
    /// A stored model meant each of those rebuilds handed the live screen a fresh, empty
    /// view model whose `.task` had already run — which is what put "Relief not found"
    /// on the screen after saving an entry from here.
    @State private var model: ReliefDetailViewModel

    /// The shared evaluation, read live. `ReliefDetailViewModel.refresh()` copies out of
    /// it rather than reading it through, so now that this screen survives a write it
    /// needs to be told when to copy again — see `.task(id:)` below.
    private let context: YearContext

    init(model: ReliefDetailViewModel, context: YearContext) {
        _model = State(initialValue: model)
        self.context = context
    }

    var body: some View {
        List {
            if let assessment = model.assessment {
                Section {
                    labelled("Cap", assessment.cap)
                    labelled("Claimed", assessment.claimed)
                    // Both figures, labelled. `claimed` is what the user entered;
                    // `allowed` is what LHDN would permit once caps bind. Showing one
                    // without the other either hides a trim or overstates the claim.
                    labelled("Allowed", assessment.allowed)
                    labelled("Still claimable", assessment.headroom)
                    if let saved = assessment.taxSaved {
                        labelled("Tax saved", saved)
                    }
                }

                if case .needsInfo(let questions) = assessment.eligibility {
                    Section("To claim this") {
                        ForEach(questions, id: \.self) { question in
                            Label(ReliefCopy.text(for: question), systemImage: "questionmark.circle")
                        }
                    }
                }

                if case .ineligible(let reasons) = assessment.eligibility {
                    Section("Why you cannot claim this") {
                        ForEach(reasons, id: \.self) { reason in
                            Label(reason, systemImage: "xmark.circle")
                        }
                    }
                }

                if !model.subLimits.isEmpty {
                    Section("Within this relief") {
                        ForEach(model.subLimits) { child in
                            NavigationLink(value: child.code) {
                                HStack {
                                    Text(child.name)
                                    Spacer()
                                    MoneyText(amount: child.headroom, font: .subheadline)
                                }
                            }
                        }
                    }
                }

                if !model.requirements.isEmpty {
                    Section("Documents") {
                        ForEach(model.requirements, id: \.kind) { check in
                            Label(ReliefCopy.text(for: check.kind),
                                  systemImage: check.isSatisfied ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(check.isSatisfied ? Color.primary : Color.orange)
                        }
                    }
                }

                Section("Entries") {
                    if model.entries.isEmpty {
                        Text("Nothing logged for this relief yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.entries) { entry in
                            NavigationLink(value: EntryRoute(entryID: entry.id)) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(entry.vendor.isEmpty ? "Untitled" : entry.vendor)
                                        if entry.needsDocument {
                                            Text("Missing a document")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer()
                                    MoneyText(amount: entry.amount, font: .subheadline)
                                }
                            }
                        }
                    }
                }

                // Spec §13: the disclaimer is not conditional on the relief happening to
                // carry an LHDN link. Nesting it inside `if let url` meant every relief
                // without a source URL showed its figures with nothing saying they are
                // estimates — the exact mistake the mitigation exists to prevent.
                Section {
                    if let url = model.sourceURL {
                        Link("LHDN source", destination: url)
                    }
                    if let notes = model.notes {
                        Text(notes).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Estimate only. Verify with LHDN before you file.")
                }
            } else {
                ContentUnavailableView("Relief not found",
                                       systemImage: "questionmark.folder",
                                       description: Text("This relief is not part of the \(String(model.yearOfAssessment)) rulebook."))
            }
        }
        .navigationTitle(model.assessment?.name ?? "Relief")
        .navigationBarTitleDisplayMode(.inline)
        // Re-copies whenever the shared evaluation changes, which is what a save, delete
        // or undo from the entry editor pushed on top of this screen produces. `.task`
        // alone fires once per view identity and this screen's identity now survives
        // those writes, so it would sit showing pre-save figures. `EvaluationResult` is
        // `Hashable`, so an unchanged evaluation does not re-fire.
        .task(id: context.result) { await model.refresh() }
        // `EvaluationResult` carries amounts, eligibility, requirements and unresolved
        // entries — not an entry's `vendor`, `note` or `spentOn`, which `model.entries`
        // (and the "Entries" section above) also reads from `store.entryDrafts`. Editing
        // only one of those fields and saving produces an *equal* `EvaluationResult`, so
        // `.task(id:)` above does not re-fire and this screen would still show the value
        // the user just replaced. `.onAppear` re-fires on pop-back where `.task(id:)`
        // does not, covering that case; `.task(id:)` stays because it covers the result
        // changing while this screen is still visible, which `.onAppear` would not catch.
        .onAppear { Task { await model.refresh() } }
    }

    private func labelled(_ title: String, _ amount: Money) -> some View {
        HStack {
            Text(title)
            Spacer()
            MoneyText(amount: amount, font: .body, weight: .medium)
        }
    }
}
