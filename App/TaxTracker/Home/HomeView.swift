import SwiftUI
import TaxKit
import TaxPresentation

struct HomeView: View {

    @Bindable var model: HomeViewModel
    /// Switch to the Docs and Reliefs tabs. Home does not own that navigation, so it asks.
    let onShowDocuments: () -> Void
    let onShowAllReliefs: () -> Void
    /// See `ReliefsListView.namespace`. Home's own, not the Reliefs tab's: both screens
    /// key their sources on the relief code, and two live sources sharing an id in one
    /// namespace is ambiguous.
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnswering = false
    /// Spec §11.2: no fixed point sizes. This is the one number the screen exists for, so
    /// leaving it unscaled while every label around it grows inverts the hierarchy at the
    /// larger accessibility sizes — the headline ends up smaller than its own caption.
    /// `relativeTo: .largeTitle` ties its growth curve to the closest built-in style.
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 44

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // With nothing logged the headline is the sum of every relief's whole cap
                // — the rulebook's theoretical maximum, not this person's money. Showing
                // it as "still claimable" on a first launch was the most overstated figure
                // in the app, on the first screen anyone sees.
                if model.hasLoggedAnything {
                    headline
                } else {
                    firstRun
                }
                prompts
                if model.hasLoggedAnything {
                    opportunities
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            // A readable measure, centred. Home is the one screen built from a ScrollView
            // and a VStack rather than a List, so it is the one screen that stretched to
            // the full width of an iPad: a relief name at the left edge and its figure a
            // thousand points away at the right, with the eye asked to connect them.
            // `List` already does this for itself, which is why the other screens did not
            // need it.
            //
            // Not the three-column layout spec §11 describes for iPad — that is a
            // navigation change, not a width one, and remains to do.
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            await model.refresh()
            #if DEBUG
            // The sheet is presented from this view's own state, so RootView's
            // `-relio-screen` switch cannot reach it. Opened here instead.
            if DemoHarness.screen == "questions" { isAnswering = true }
            #endif
        }
        .sheet(isPresented: $isAnswering) {
            ProfileQuestionsSheet(model: model.profileQuestions()) {
                // Answering changes eligibility, so every figure on this screen moves.
                Task { await model.refresh() }
            }
        }
    }

    /// Spec §11.5: empty states are the design, not an afterthought. Home had one written
    /// and unreachable — `opportunities` is never empty, because every unclaimed relief
    /// reports its whole cap as headroom.
    ///
    /// It names the two things worth doing rather than a figure, because there is no
    /// honest figure yet. The prompts below it still show: a question the user can answer
    /// is real work whether or not anything has been logged.
    private var firstRun: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing logged yet")
                .font(.title2.weight(.bold))
            Text("Add a receipt and Relio will show what it is worth in tax, and how much "
                 + "room each relief has left.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Estimate only. Verify with LHDN before you file.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }

    // The only large number on the screen. Spec §11.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                MoneyText(amount: model.headline, font: .system(size: headlineSize), weight: .bold)
                    // Spec §11.3: rolling digits are motion. Reduce Motion swaps the
                    // value outright instead.
                    .contentTransition(reduceMotion ? .identity : .numericText())
                Text(model.headlineKind == .taxSaved ? "in tax still claimable" : "of relief still claimable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            // Spec §13: the largest computed figure in the app had nothing anywhere on
            // the screen saying it is an estimate. A footnote, not a banner — it has to
            // be readable without competing with the number it qualifies. Kept out of the
            // combined element above so VoiceOver reads the figure first and the caveat
            // as its own stop, rather than one long run-on label.
            Text("Estimate only. Verify with LHDN before you file.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var prompts: some View {
        VStack(spacing: 10) {
            if !model.prompts.unansweredQuestions.isEmpty {
                Button {
                    isAnswering = true
                } label: {
                    promptRow(
                        systemImage: "questionmark.circle",
                        title: model.prompts.unansweredQuestions.count == 1
                            ? "Answer 1 question"
                            : "Answer \(model.prompts.unansweredQuestions.count) questions",
                        trailing: model.prompts.unlockableRelief)
                }
                .buttonStyle(.plain)
            }
            if model.prompts.claimsMissingDocuments > 0 {
                Button(action: onShowDocuments) {
                    promptRow(
                        systemImage: "doc.viewfinder",
                        title: model.prompts.claimsMissingDocuments == 1
                            ? "1 claim needs a document"
                            : "\(model.prompts.claimsMissingDocuments) claims need documents",
                        trailing: nil)
                }
                .buttonStyle(.plain)
            }
            if model.prompts.unresolvedEntryCount > 0 {
                // The last prompt on this screen that led nowhere. `UnresolvedEntry`
                // documents itself as existing "so the UI can show an actionable amber
                // row"; it now opens the input history filtered to exactly those entries.
                NavigationLink(value: EntryHistoryRoute(
                    restrictedTo: Set(model.prompts.unresolvedEntryIDs))) {
                    promptRow(
                        systemImage: "exclamationmark.triangle",
                        title: model.prompts.unresolvedEntryCount == 1
                            ? "1 entry uses a relief this year's rules don't recognise"
                            : "\(model.prompts.unresolvedEntryCount) entries use a relief this year's rules don't recognise",
                        trailing: nil)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func promptRow(systemImage: String, title: String, trailing: Money?) -> some View {
        AdaptiveRow(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                Text(title)
            }
        } trailing: {
            HStack(spacing: 6) {
                if let trailing {
                    // One Text, so "unlock" and the figure wrap together as words rather
                    // than competing for one line with the chevron. Side by side they
                    // truncated the amount to "RM 20,0…" at the largest type sizes, and a
                    // truncated figure is not the figure. `monospacedDigit` is kept, which
                    // is the other thing MoneyText would have given it.
                    Text("unlock \(trailing.formatted())")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                // These rows have looked like buttons and done nothing since the first
                // build. Now that they lead somewhere, they get the chevron that says so.
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var opportunities: some View {
        if model.opportunities.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Biggest opportunities")
                    .font(.headline)
                ForEach(model.opportunities) { row in
                    NavigationLink(value: row.code) {
                        OpportunityRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: row.code, in: namespace)
                }
                if model.remainingOpportunityCount > 0 {
                    Button(action: onShowAllReliefs) {
                        // "See all 17" left the reader counting what the 17 were. It is
                        // reliefs, and saying so costs one word.
                        Text("See all \(model.remainingOpportunityCount + model.opportunities.count) reliefs")
                            .font(.subheadline)
                    }
                }
            }
        }
    }
}

struct OpportunityRowView: View {
    let row: OpportunityRow

    var body: some View {
        AdaptiveRow {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.shortName)
                // A bar at zero is not information, it is a horizontal rule sitting
                // under a label — and every untouched relief drew one, so the list read
                // as a stack of underlined headings. Shown only once there is progress
                // to show.
                if row.usedPercent > 0 && !row.needsAnswer {
                    ProgressView(value: Double(row.usedPercent), total: 100)
                        .tint(.accentColor)
                }
            }
        } trailing: {
            trailingFigure
        }
        // Spec §11.8: VoiceOver reads the amounts, never "68 percent".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// `OpportunityRow.needsAnswer` has always documented that such a row "renders as a
    /// question rather than a figure". Until now nothing rendered it: an unanswered
    /// relief showed the same bold ringgit figure as money already sitting there, and its
    /// figure is the whole cap — what the relief *would* be worth if the answer went the
    /// user's way. Two different kinds of number in one typeface reads as one kind.
    @ViewBuilder
    private var trailingFigure: some View {
        if row.needsAnswer {
            HStack(spacing: 6) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Answer to unlock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MoneyText(amount: row.headroom, font: .subheadline, weight: .regular)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.tint)
            }
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(amount: row.headroom, font: .subheadline, weight: .semibold)
                if let saved = row.taxSaved {
                    // "→ RM 1,520.00" said nothing about what the smaller figure was.
                    // It is the tax the headroom above is worth, and the row now says so.
                    HStack(spacing: 3) {
                        MoneyText(amount: saved, font: .caption)
                        Text("in tax").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The full LHDN name, not the short one: length costs a screen reader nothing, and
    /// "Serious medical" is less use than the name that says which treatments count.
    private var accessibilityLabel: String {
        guard !row.needsAnswer else {
            // "Still claimable" was the old wording here too, and it was the same lie the
            // visible row told: this money is not claimable until a question is answered.
            return "\(row.name), answer one question to unlock \(row.headroom.formatted())"
        }
        var label = "\(row.name), \(row.headroom.formatted()) still claimable"
        if let saved = row.taxSaved {
            label += ", worth \(saved.formatted()) in tax"
        }
        return label
    }
}
