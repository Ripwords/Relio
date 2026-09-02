import SwiftUI

/// A label and a figure that share a line until they cannot, and stack when they cannot.
///
/// Every list row in this app is "something on the left, an amount on the right", and at
/// the largest Dynamic Type sizes that shape stops working: the label hyphenates mid-word
/// ("AIA Med-ical") and the amount beside it splits mid-number ("RM 3,50" over "0.00"),
/// which is worse than a wrapped label because a figure broken in half can be misread as
/// a different figure.
///
/// `ReliefDetailView` already solved this for its four money rows with a hand-written
/// `ViewThatFits`, and `IncomeView` did the same for its source headers. Writing it a
/// third and fourth time is how the Docs tab and Home's prompt rows shipped broken at
/// accessibility sizes — so it lives here now, and a new row gets it by construction
/// rather than by remembering.
struct AdaptiveRow<Leading: View, Trailing: View>: View {

    private let spacing: CGFloat
    private let leading: Leading
    private let trailing: Trailing

    init(spacing: CGFloat = 12,
         @ViewBuilder leading: () -> Leading,
         @ViewBuilder trailing: () -> Trailing) {
        self.spacing = spacing
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                leading
                Spacer(minLength: spacing)
                trailing
            }
            // The fallback. Leading-aligned rather than centred, so a stacked row still
            // reads down the same edge as every row that did fit.
            VStack(alignment: .leading, spacing: 6) {
                leading
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
