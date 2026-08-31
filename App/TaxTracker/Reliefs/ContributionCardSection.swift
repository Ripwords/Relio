import SwiftUI
import TaxKit
import TaxPresentation

/// The contribution card, as a `Section` of a relief's detail list.
///
/// Every string on screen here was decided in `ReliefCopy.card(for:code:year:cap:)`, which
/// is inside `swift test`'s reach; this view picks none of them and derives none of them.
/// Its whole job is arrangement, and the one piece of state it owns is the failure of a tap.
struct ContributionCardSection: View {

    let card: ContributionCard
    let code: ReliefCode
    let onAccept: () async -> Bool
    let onAnswer: () -> Void

    /// Set when the one-tap accept did not write. A tap that files nothing and says nothing
    /// is indistinguishable from a tap that missed the button, and the user's next move
    /// either way is to walk off believing the relief is claimed.
    @State private var acceptError: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                if let amount = card.headlineAmount {
                    // Stacked, never paired across a row. At the largest Dynamic Type
                    // sizes a label and a figure sharing a line truncate one of them, and
                    // a truncated amount on a card that exists to state an amount is the
                    // defect.
                    Text(card.headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    MoneyText(amount: amount, font: .title2, weight: .semibold)
                } else {
                    Text(card.headline)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(card.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let caveat = card.caveat {
                // Secondary, never orange. This is Relio declining to guess, which is the
                // app working correctly; dressed as a warning it would read as something
                // the user has done wrong.
                Label {
                    Text(caveat).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let action = card.action {
                actionRow(action)
            }

            ForEach(Array(card.sourceURLs.enumerated()), id: \.offset) { index, url in
                // One label for every link rather than a title per URL. A per-URL title
                // would be a string this view invented, and App/ is where an invented
                // string has no test to catch it being wrong.
                Link(destination: url) {
                    Text(card.sourceURLs.count == 1
                         ? "Where this comes from"
                         : "Where this comes from (\(index + 1))")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let acceptError {
                Text(acceptError)
                    .foregroundStyle(.orange)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The error belongs to one tap on one card. This view holds its place in the list
        // while the advice changes underneath it, so without this a failure would go on
        // sitting under a card that has since become a different one.
        .onChange(of: card) { acceptError = nil }
    }

    @ViewBuilder
    private func actionRow(_ action: ContributionCard.Action) -> some View {
        switch action.kind {
        case .addExactly:
            Button(action.title) {
                Task {
                    acceptError = nil
                    if await onAccept() == false {
                        acceptError = "Relio could not add that figure. Nothing was claimed. Try again."
                    }
                }
            }
        case .startFrom(let amount):
            // A link, not a button. This figure is a floor, so the user has to raise it
            // against their own statement before it is filed; opening the editor with it
            // already in the field is the whole offer, and a button here would file a
            // number Relio knows to be too low.
            NavigationLink(value: PrefilledEntryRoute(code: code, amount: amount)) {
                Text(action.title)
            }
        case .answerQuestions:
            Button(action.title) { onAnswer() }
        }
    }
}
