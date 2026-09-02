import SwiftUI
import TaxKit
import TaxData
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

    /// Held only to build the questions sheet's own view model, which needs a writer.
    /// `ReliefDetailViewModel` reads through `context` and never exposes its store.
    private let store: TaxStore

    @State private var isAnswering = false

    init(model: ReliefDetailViewModel, context: YearContext, store: TaxStore) {
        _model = State(initialValue: model)
        self.context = context
        self.store = store
    }

    var body: some View {
        List {
            if let assessment = model.assessment {
                Section {
                    // The one figure this screen exists to give, at the size that says
                    // so. Five equal rows made the reader find "still claimable" fourth
                    // down a list where every line looked equally important — the same
                    // flat treatment Home was fixed out of.
                    headline(assessment)
                } header: {
                    // Where the full LHDN name lives now that the title is the short one.
                    // `.textCase(nil)` because a grouped header would otherwise shout it
                    // in capitals, and this is a sentence, not a label.
                    Text(assessment.name)
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    labelled("Cap", assessment.cap)
                    labelled("Claimed", assessment.claimed)
                    // Both figures, labelled. `claimed` is what the user entered;
                    // `allowed` is what LHDN would permit once caps bind. Showing one
                    // without the other either hides a trim or overstates the claim.
                    labelled("Allowed", assessment.allowed)
                } header: {
                    Text("How that is worked out")
                }

                if let card = ReliefCopy.card(for: model.advice,
                                              code: model.code,
                                              year: model.yearOfAssessment,
                                              cap: assessment.cap) {
                    ContributionCardSection(card: card,
                                            code: model.code,
                                            onAccept: { await model.acceptSuggestion() },
                                            onAnswer: { isAnswering = true })
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
        // The short name, because an inline title has one line and LHDN's own name
        // truncates to "Lifestyle — books, computer, smartp…". The full name is not lost:
        // it heads the figures section below, where it has the width to be read.
        .navigationTitle(model.assessment.map {
            ReliefCopy.shortName(for: model.code, fullName: $0.name)
        } ?? "Relief")
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
        .sheet(isPresented: $isAnswering) {
            // Refreshed on dismissal, and it has to be here. Answering writes a contributor
            // profile and income sources, none of which the rulebook evaluates, so
            // `context.result` comes back equal and the `.task(id:)` above does not re-fire;
            // `.onAppear` does not fire on a sheet closing either. Without this the card sits
            // there still asking the questions the user has just answered.
            Task { await model.refresh() }
        } content: {
            ContributionQuestionsSheet(
                model: ContributionQuestionsViewModel(store: store, questions: model.questions))
        }
    }

    /// The headroom, large, with what it is worth in tax under it — the same shape as
    /// Home's headline, because it answers the same question about one relief instead of
    /// all of them.
    ///
    /// "Exhausted" is said in words rather than shown as RM 0.00. A zero here is a good
    /// outcome, not an empty one, and a bare zero reads as the latter.
    @ViewBuilder
    private func headline(_ assessment: ReliefAssessment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if assessment.headroom > .zero {
                MoneyText(amount: assessment.headroom, font: .largeTitle, weight: .bold)
                Text("still claimable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let saved = assessment.taxSaved, saved > .zero {
                    Text("worth \(saved.formatted()) in tax")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text("Fully claimed")
                    .font(.title2.weight(.semibold))
                Text("You have used all of this relief for this year.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// `ViewThatFits` rather than a bare `HStack`, the same way `IncomeView` builds its
    /// source headers. At the largest Dynamic Type sizes the label and the figure cannot
    /// share a line, and both lose: "Still claimable" breaks to "Still claim-able" and
    /// the amount beside it breaks to "RM 4,000." over "00". These four rows are the
    /// figures the whole screen is about.
    private func labelled(_ title: String, _ amount: Money) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                Spacer()
                MoneyText(amount: amount, font: .body, weight: .medium)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                MoneyText(amount: amount, font: .body, weight: .medium)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
