import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

struct RootView: View {

    let store: TaxStore
    @State private var context: YearContext
    @State private var home: HomeViewModel
    @State private var editingEntry: EntryEditorViewModel?
    @State private var showUndo = false
    @State private var lastDeleted: EntryEditorViewModel?

    init(store: TaxStore) {
        self.store = store
        let context = YearContext(store: store,
                                  loader: BundledRuleSetLoader(),
                                  year: BundledRuleSetLoader().availableYears.last ?? 2025)
        _context = State(initialValue: context)
        _home = State(initialValue: HomeViewModel(context: context, store: store))
    }

    var body: some View {
        TabView {
            NavigationStack {
                content
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: ReliefsRoute.self) { _ in
                        ReliefsListView(model: ReliefsListViewModel(context: context))
                    }
                    .navigationDestination(for: ReliefCode.self) { code in
                        ReliefDetailView(model: ReliefDetailViewModel(context: context,
                                                                      store: store,
                                                                      code: code))
                    }
                    .navigationDestination(for: EntryRoute.self) { route in
                        EntryEditorView(
                            model: EntryEditorViewModel(context: context, store: store,
                                                        editing: route.entryID),
                            onDeleted: handleDeleted)
                    }
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Menu {
                                ForEach(context.availableYears.reversed(), id: \.self) { year in
                                    Button {
                                        Task {
                                            await context.switchYear(to: year)
                                            await home.refresh()
                                        }
                                    } label: {
                                        // The check marks the current year; Compare joins
                                        // this menu in a later plan, which is why the
                                        // switcher lives in the title rather than a tab.
                                        Label("YA \(String(year))",
                                              systemImage: year == context.year ? "checkmark" : "")
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("YA \(String(context.year))").fontWeight(.semibold)
                                    Image(systemName: "chevron.down").font(.caption2)
                                }
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                editingEntry = EntryEditorViewModel(context: context,
                                                                    store: store,
                                                                    editing: nil)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel("Add an entry")
                        }
                    }
            }
            .tabItem { Label("Home", systemImage: "house") }

            NavigationStack {
                ContentUnavailableView("Documents",
                                       systemImage: "doc.text",
                                       description: Text("Receipt capture arrives in a later release."))
            }
            .tabItem { Label("Docs", systemImage: "doc.text") }

            NavigationStack {
                ContentUnavailableView("Ask",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("The on-device assistant arrives in a later release."))
            }
            .tabItem { Label("Ask", systemImage: "bubble.left.and.bubble.right") }
        }
        .sheet(item: $editingEntry) { model in
            EntryEditorView(model: model, onDeleted: handleDeleted)
        }
        .overlay(alignment: .bottom) {
            if showUndo, let lastDeleted {
                UndoToast(message: "Entry deleted",
                          undo: {
                              await lastDeleted.undoDelete()
                              await home.refresh()
                          },
                          isPresented: $showUndo)
                .padding(.bottom, 60)
            }
        }
        .animation(.spring(duration: 0.3), value: showUndo)
        .task {
            await context.load()
            await home.refresh()
        }
    }

    private func handleDeleted(_ model: EntryEditorViewModel) {
        lastDeleted = model
        showUndo = true
        Task { await home.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch context.status {
        case .idle, .loading:
            ProgressView()
        case .ready:
            HomeView(model: home)
        case .unavailable(let message):
            // The user's entries still exist. Saying so matters — a blank screen here
            // reads as data loss.
            ContentUnavailableView("No rules for \(String(context.year))",
                                   systemImage: "calendar.badge.exclamationmark",
                                   description: Text(message))
        }
    }
}
