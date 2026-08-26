import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

struct RootView: View {

    let store: TaxStore
    @State private var context: YearContext
    @State private var home: HomeViewModel
    /// Held here for the same reason `home` is: `IncomeView` is rebuilt every time the
    /// destination closure runs, and a model built inside that closure would hand the
    /// pushed screen a brand-new empty one on every re-render, after its `.task` had
    /// already fired.
    @State private var income: IncomeViewModel
    /// The year menu pushes Income, and a menu item cannot be a `NavigationLink`, so the
    /// stack needs a path to append to.
    @State private var path = NavigationPath()
    @State private var editingEntry: EntryEditorViewModel?
    @State private var showUndo = false
    @State private var lastDeleted: EntryEditorViewModel?
    // `nil` means the preference has not been read yet. Defaulting this to "show
    // onboarding" would flash the welcome screen at every returning user on every
    // launch.
    @State private var needsOnboarding: Bool?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: TaxStore) {
        self.store = store
        // The newest shipped year is the fallback, not the answer. The year the user was
        // last on lives in `UserPreferences`, which only an `await` can read — see the
        // `.task` below.
        let context = YearContext(store: store,
                                  loader: BundledRuleSetLoader(),
                                  year: BundledRuleSetLoader().availableYears.last ?? 2025)
        _context = State(initialValue: context)
        _home = State(initialValue: HomeViewModel(context: context, store: store))
        _income = State(initialValue: IncomeViewModel(context: context, store: store))
    }

    var body: some View {
        Group {
            if needsOnboarding == true {
                OnboardingView(model: OnboardingViewModel(store: store, year: context.year)) {
                    needsOnboarding = false
                    Task { await context.reload(); await home.refresh() }
                }
            } else if needsOnboarding == false {
                tabs
            } else {
                ProgressView()
            }
        }
        .task {
            let preferences = try? await store.preferences()
            needsOnboarding = !(preferences?.hasCompletedOnboarding ?? false)
            await resumeLastViewedYear(preferences?.lastViewedYear)
            await home.refresh()
        }
    }

    /// Launch resumes on the year the user left off on. `switchYear` is the only way in:
    /// it owns the supersede guard and writes the preference back, and it also performs
    /// the load, so the fallback path is the one that calls `load()` directly.
    ///
    /// `0` is the default a never-written preference carries, and a year whose rulebook
    /// this build no longer ships would strand the user on a permanent "no rules"
    /// screen — both fall back to the newest available year the initialiser already
    /// chose.
    private func resumeLastViewedYear(_ remembered: Int?) async {
        guard let remembered,
              remembered != context.year,
              context.availableYears.contains(remembered) else {
            await context.load()
            return
        }
        await context.switchYear(to: remembered)
    }

    private var tabs: some View {
        TabView {
            NavigationStack(path: $path) {
                content
                    .navigationBarTitleDisplayMode(.inline)
                    // Every destination builds its view model at the call site but hands
                    // it straight to a `@State` inside the destination view, so the model
                    // outlives a body evaluation of this view. Constructing one that is
                    // *read* from `body` — as these closures used to — meant every
                    // re-render handed the pushed screen a brand-new empty model whose
                    // `.task` had already fired and would not fire again.
                    .navigationDestination(for: ReliefsRoute.self) { _ in
                        ReliefsListView(model: ReliefsListViewModel(context: context))
                    }
                    .navigationDestination(for: ReliefCode.self) { code in
                        ReliefDetailView(model: ReliefDetailViewModel(context: context,
                                                                      store: store,
                                                                      code: code),
                                         context: context)
                    }
                    .navigationDestination(for: IncomeRoute.self) { _ in
                        IncomeView(model: income)
                    }
                    .navigationDestination(for: EntryRoute.self) { route in
                        EntryEditorView(
                            model: EntryEditorViewModel(context: context, store: store,
                                                        editing: route.entryID),
                            presentation: .pushed,
                            onSaved: handleSaved,
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
                                            // Income is per-year too, and its model
                                            // outlives the switch.
                                            await income.refresh()
                                        }
                                    } label: {
                                        // The check marks the current year; Compare joins
                                        // this menu in a later plan, which is why the
                                        // switcher lives in the title rather than a tab.
                                        if year == context.year {
                                            Label("YA \(String(year))", systemImage: "checkmark")
                                        } else {
                                            Text("YA \(String(year))")
                                        }
                                    }
                                }
                                Divider()
                                Button {
                                    path.append(IncomeRoute())
                                } label: {
                                    Label("Income", systemImage: "banknote")
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
            EntryEditorView(model: model,
                            presentation: .sheet,
                            onSaved: handleSaved,
                            onDeleted: handleDeleted)
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
        // Spec §11.3: honour Reduce Motion. A `nil` animation still applies the change,
        // it just does not travel to get there.
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: showUndo)
    }

    /// Home is no longer torn down and rebuilt by every write — that teardown was the
    /// defect this wave fixes — so it no longer re-runs its `.task` afterwards. Its view
    /// model copies out of `context.result` rather than reading it live, so the save path
    /// has to say when to copy again, exactly as the delete path already did.
    private func handleSaved() {
        Task { await home.refresh() }
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
