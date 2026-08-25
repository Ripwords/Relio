import SwiftUI

/// A transient "Deleted · Undo" bar.
///
/// Spec §11.6: every destructive action is undoable, on every platform. The undo action
/// is passed in rather than owned here, because what to undo is the view model's
/// business and a toast that knows about entries would need rewriting for documents.
struct UndoToast: View {
    let message: String
    let undo: () async -> Void
    @Binding var isPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            Text(message)
            Spacer()
            Button("Undo") {
                Task {
                    await undo()
                    isPresented = false
                }
            }
            .fontWeight(.semibold)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thickMaterial, in: Capsule())
        .padding(.horizontal, 20)
        // Spec §11.3: Reduce Motion means the toast must not travel. It still has to
        // arrive and leave visibly — a cross-fade is the substitution Apple's own
        // components make, and dropping the transition entirely would make the only
        // route to undo a delete appear with no cue at all.
        .transition(reduceMotion
                    ? AnyTransition.opacity
                    : AnyTransition.move(edge: .bottom).combined(with: .opacity))
        .task {
            // Bound to the view's lifetime: when the toast goes away, so does the timer.
            // A detached sleep would keep firing and could restore an entry the user has
            // since re-created.
            try? await Task.sleep(for: .seconds(5))
            isPresented = false
        }
    }
}
