import SwiftUI
import TaxKit
import TaxPresentation

struct ReliefsListView: View {

    /// `@State`, not a stored `let`: the view model must outlive a body evaluation of the
    /// view that pushed this one. `State(initialValue:)` keeps the first model handed in
    /// and drops every later one, so a re-render cannot swap a loaded screen for an empty
    /// one.
    @State private var model: ReliefsListViewModel

    /// Shared with the detail screen's `navigationTransition` so the row the user tapped
    /// is the thing that grows into it. Spec §11.3 asks for exactly two kinds of motion,
    /// and this is the first: "matchedGeometryEffect from row to detail".
    ///
    /// The zoom navigation transition rather than a bare `matchedGeometryEffect`, because
    /// the two views live on opposite sides of a `NavigationStack` push and a raw
    /// namespace effect does not cross one. It also honours Reduce Motion itself.
    let namespace: Namespace.ID

    /// Where a tapped relief goes.
    ///
    /// `nil` on iPhone: the row is a `NavigationLink` and the detail is pushed onto the
    /// stack. Bound on iPad, where spec §11 draws the detail as a third column beside this
    /// list rather than on top of it — so the row sets a selection and the split view
    /// renders the detail itself.
    let selection: Binding<ReliefCode?>?

    init(model: ReliefsListViewModel,
         namespace: Namespace.ID,
         selection: Binding<ReliefCode?>? = nil) {
        _model = State(initialValue: model)
        self.namespace = namespace
        self.selection = selection
    }

    var body: some View {
        @Bindable var model = model
        return Group {
            if let selection {
                // Buttons with an explicit selected background rather than
                // `List(selection:)`, which is unavailable on iOS for a single optional
                // binding. The row still has to look and read as chosen, because the
                // detail beside it is the consequence of that choice.
                List {
                    ForEach(model.sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                Button {
                                    selection.wrappedValue = row.code
                                } label: {
                                    ReliefRowView(row: row).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(selection.wrappedValue == row.code
                                                   ? Color.accentColor.opacity(0.12)
                                                   : Color.clear)
                                .accessibilityAddTraits(selection.wrappedValue == row.code
                                                        ? .isSelected : [])
                            }
                        }
                    }
                }
            } else {
                List {
                    ForEach(model.sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                NavigationLink(value: row.code) {
                                    ReliefRowView(row: row)
                                }
                                .matchedTransitionSource(id: row.code, in: namespace)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Reliefs")
        .searchable(text: $model.searchText, prompt: "Search reliefs")
        .onChange(of: model.searchText) { model.refresh() }
        .onAppear { model.refresh() }
        .overlay {
            if model.sections.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }
}

struct ReliefRowView: View {
    let row: ReliefRow

    var body: some View {
        AdaptiveRow {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.shortName)
                // See `OpportunityRowView`: a bar at zero draws a rule under the name and
                // says nothing. Most reliefs in this list are untouched, so most rows were
                // drawing one.
                if (row.state == .claimable || row.state == .exhausted) && row.usedPercent > 0 {
                    ProgressView(value: Double(row.usedPercent), total: 100)
                        .tint(row.state == .exhausted ? .secondary : .accentColor)
                }
            }
        } trailing: {
            trailing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .claimable:
            MoneyText(amount: row.headroom, font: .subheadline, weight: .semibold)
        case .exhausted:
            Text("Full").font(.subheadline).foregroundStyle(.secondary)
        case .granted:
            // The amount, not a status word: it is real relief the user is getting, and
            // the section heading already says it arrived without being claimed.
            MoneyText(amount: row.allowed, font: .subheadline).foregroundStyle(.secondary)
        case .needsAnswer:
            Image(systemName: "questionmark.circle").foregroundStyle(.tint)
        case .needsDependent:
            // A person rather than a question mark: what is missing is somebody to claim
            // for, not an answer about the user.
            Image(systemName: "person.badge.plus").foregroundStyle(.tint)
        case .unavailable:
            Text("N/A").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// Spec §11.8: "Lifestyle, RM 1,700 of RM 2,500 used", never "68 percent".
    private var accessibilityLabel: String {
        switch row.state {
        case .claimable, .exhausted:
            return "\(row.name), \(row.allowed.formatted()) of \(row.cap.formatted()) used"
        case .granted:
            return "\(row.name), \(row.allowed.formatted()) granted automatically"
        case .needsAnswer:
            return "\(row.name), needs an answer before it can be claimed"
        case .needsDependent:
            return "\(row.name), add a dependant before it can be claimed"
        case .unavailable:
            return "\(row.name), not applicable to you"
        }
    }
}
