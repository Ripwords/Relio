import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

/// The household the child, parent and grandparent reliefs are claimed for.
///
/// Nothing in the app could add one. The entry editor's "Which person" picker has always
/// read `store.dependentDrafts()` and no screen ever wrote to it, so the picker was
/// permanently empty and the five child reliefs could not be claimed at all.
struct DependentsView: View {

    @State private var model: DependentsViewModel
    @State private var editing: DependentDraft?

    /// Told when the household changed, so the screens the user walks back to are not
    /// showing figures worked out before this child existed. `context.reload()` refreshes
    /// the shared evaluation; Home and Documents copy out of it and have to be told to
    /// copy again, exactly as they are after an entry is saved.
    let onChanged: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: DependentsViewModel, onChanged: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onChanged = onChanged
    }

    var body: some View {
        Group {
            if model.dependents.isEmpty {
                ContentUnavailableView {
                    Label("No one added yet", systemImage: "person.2")
                } description: {
                    Text("Add your children, parents or grandparents and Relio can work out which reliefs they unlock.")
                } actions: {
                    Button("Add someone") { editing = DependentDraft() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(model.dependents) { row in
                        Button { editing = row.draft } label: {
                            DependentRowView(row: row)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                Task {
                                    if await model.delete(id: row.id) { onChanged() }
                                }
                            }
                        }
                    }
                } 
            }
        }
        .navigationTitle("Dependants")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = DependentDraft() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a dependant")
            }
        }
        .sheet(item: $editing) { draft in
            DependentEditorView(draft: draft, year: model.year) { edited in
                let saved = await model.save(edited)
                if saved { onChanged() }
                return saved
            }
        }
        .task {
            await model.refresh()
            #if DEBUG
            // The editor is presented from this view's own state, so RootView's route
            // switch cannot reach it.
            switch DemoHarness.screen {
            case "dependent-editor": editing = model.dependents.first?.draft
            case "dependent-new": editing = DependentDraft()
            default: break
            }
            #endif
        }
        // Spec §11.6. Deleting a dependant takes every child relief claimed against them
        // with it, which is a large and silent consequence for one swipe.
        .overlay(alignment: .bottom) {
            if let removed = model.lastDeleted {
                UndoToast(message: "Deleted \(removed.name.isEmpty ? "dependant" : removed.name)",
                          undo: { await model.undoDelete(); onChanged() },
                          isPresented: Binding(get: { model.lastDeleted != nil },
                                               set: { if !$0 { model.clearUndo() } }))
                    .padding(.bottom, 12)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: model.lastDeleted)
    }
}

struct DependentRowView: View {
    let row: DependentRow

    var body: some View {
        // A plain HStack, not an AdaptiveRow. That one exists to stop a label and a
        // *figure* fighting over a line, and stacking is the right answer there. A
        // chevron is an affordance rather than content: stacked, it lands on a line of
        // its own under the text and reads as a broken row. The subtitle wraps inside
        // the VStack instead, which is what it should do.
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name.isEmpty ? "Unnamed" : row.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name.isEmpty ? "Unnamed" : row.name), \(subtitle)")
    }

    /// What decides which reliefs this person unlocks: their relationship, their age in
    /// the year being viewed, and how the claim is split.
    private var subtitle: String {
        var parts: [String] = [DependentCopy.label(for: row.kind)]
        if let age = row.age { parts.append("\(age) years old") }
        if let status = row.status {
            if status.educationLevel != .none {
                parts.append(DependentCopy.label(for: status.educationLevel))
            }
            if status.claimPercentage != 100 {
                parts.append("\(status.claimPercentage)% claimed")
            }
        }
        if row.draft.isDisabled == true { parts.append("registered disabled") }
        return parts.joined(separator: " · ")
    }
}

/// User-facing words for the two dependant enums, which carry none of their own.
enum DependentCopy {
    static func label(for kind: DependentKind) -> String {
        switch kind {
        case .child: "Child"
        case .parent: "Parent"
        case .grandparent: "Grandparent"
        }
    }

    static func label(for level: EducationLevel) -> String {
        switch level {
        case .none: "Not studying"
        case .preTertiary: "A-Level, matriculation or pre-degree"
        case .tertiaryLocal: "Tertiary, in Malaysia"
        case .tertiaryOverseas: "Tertiary, overseas"
        }
    }
}
