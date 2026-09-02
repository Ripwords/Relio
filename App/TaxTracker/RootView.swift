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
    /// Held here for the same reason `home` and `income` are: a model built inside the
    /// tab's view builder would be replaced by a fresh empty one on every re-render.
    @State private var documents: DocumentsViewModel
    @State private var selectedTab: Tab = .home
    /// Ties a relief row to the detail screen it opens. See `ReliefsListView.namespace`.
    @Namespace private var reliefTransition
    @Namespace private var homeReliefTransition
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
    @Environment(\.scenePhase) private var scenePhase

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
        _documents = State(initialValue: DocumentsViewModel(context: context, store: store))
    }

    /// Three tabs, all of them real. Two of the original three were
    /// `ContentUnavailableView` placeholders describing features that do not exist, which
    /// spent two thirds of the tab bar on apologies. Reliefs takes the Ask tab's place: it
    /// is a primary surface that was reachable only through Home's "See all" link.
    private enum Tab: Hashable { case home, reliefs, docs }

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
            #if DEBUG
            if DemoHarness.wantsSeed { await DemoHarness.seed(into: store, year: context.year) }
            if DemoHarness.wantsEmpty { await DemoHarness.markOnboarded(store, year: context.year) }
            #endif
            let preferences = try? await store.preferences()
            needsOnboarding = !(preferences?.hasCompletedOnboarding ?? false)
            // Housekeeping, not the fix: every read below already resolves duplicates, so
            // a sweep that throws leaves the figure correct and the duplicate rows on
            // disk. Swallowing is safe here for that reason and no other.
            _ = try? await store.reconcile()
            #if DEBUG
            // Overrides the remembered year, through the same `switchYear` a menu tap uses.
            if let demoYear = DemoHarness.year, context.availableYears.contains(demoYear) {
                await context.switchYear(to: demoYear)
                await income.refresh()
                await documents.refresh()
            } else {
                await resumeLastViewedYear(preferences?.lastViewedYear)
            }
            #else
            await resumeLastViewedYear(preferences?.lastViewedYear)
            #endif
            await home.refresh()
            #if DEBUG
            openDemoScreen()
            #endif
        }
        // Duplicates arriving while the app was closed are what this catches. One that
        // lands while it is already open reads correctly straight away and is collapsed
        // at the next foregrounding; a real sync-complete event would be better and is
        // its own unit of work.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                guard (try? await store.reconcile())?.changedAnything == true else { return }
                await context.reload()
                await home.refresh()
                await income.refresh()
                await documents.refresh()
            }
        }
    }

    #if DEBUG
    /// Pushes the screen `-relio-screen` names, so a screenshot run can photograph
    /// something other than Home. Appending to `path` rather than reaching into each
    /// screen means the route this takes is the same one a tap takes.
    private func openDemoScreen() {
        guard let screen = DemoHarness.screen else { return }
        switch screen {
        case "docs": selectedTab = .docs
        case "settings", "settings-household", "settings-contributor":
            path.append(SettingsRoute())
        case "compare": path.append(CompareRoute())
        case "reliefs": selectedTab = .reliefs
        case "income": path.append(IncomeRoute())
        case "history": path.append(EntryHistoryRoute())
        case "entry", "relief-picker":
            editingEntry = EntryEditorViewModel(context: context, store: store, editing: nil)
        case let name where name.hasPrefix("entry:"):
            // `entry:CODE:RINGGIT` — a prefilled editor, so a screenshot run can see the
            // amount fields in a state a blank new entry never shows.
            let parts = name.split(separator: ":")
            if parts.count == 3, let ringgit = Int(parts[2]) {
                path.append(PrefilledEntryRoute(code: ReliefCode(String(parts[1])),
                                                amount: Money(ringgit: Decimal(ringgit))))
            }
        case let name where name.hasPrefix("relief:"):
            path.append(ReliefCode(String(name.dropFirst("relief:".count))))
        default:
            print("[DemoHarness] unknown screen '\(screen)'")
        }
    }
    #endif

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


    /// The year switcher, shared by every tab that shows year-scoped figures.
    ///
    /// It used to live only in Home's toolbar, which was fine while Home was the only
    /// tab with a year in it. Reliefs and Docs are both scoped to the year too, and after
    /// they became tabs a user standing on either one saw a year's figures with nothing
    /// naming the year and no way to change it.
    ///
    /// - Parameter canCompare: Compare pushes onto Home's navigation path, so only Home's
    ///   copy of the menu offers it. The other tabs get the switcher without it rather
    ///   than a menu item that would push onto a stack the user is not looking at.
    @ViewBuilder
    private func yearMenu(canCompare: Bool) -> some View {
        Menu {
            ForEach(context.availableYears.reversed(), id: \.self) { year in
                Button {
                    Task {
                        await context.switchYear(to: year)
                        await home.refresh()
                        // Income is per-year too, and its model outlives the switch. So is
                        // Documents: its rows come from the year's requirement checks.
                        await income.refresh()
                        await documents.refresh()
                    }
                } label: {
                    if year == context.year {
                        Label("YA \(String(year))", systemImage: "checkmark")
                    } else {
                        Text("YA \(String(year))")
                    }
                }
            }
            if canCompare, context.availableYears.count > 1 {
                Divider()
                Button {
                    path.append(CompareRoute())
                } label: {
                    Label("Compare with another year", systemImage: "arrow.left.arrow.right")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("YA \(String(context.year))").fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $path) {
                content
                    .navigationBarTitleDisplayMode(.inline)
                    // Every destination builds its view model at the call site but hands
                    // it straight to a `@State` inside the destination view, so the model
                    // outlives a body evaluation of this view. Constructing one that is
                    // *read* from `body` — as these closures used to — meant every
                    // re-render handed the pushed screen a brand-new empty model whose
                    // `.task` had already fired and would not fire again.
                    .navigationDestination(for: ReliefCode.self) { code in
                        ReliefDetailView(model: ReliefDetailViewModel(context: context,
                                                                      store: store,
                                                                      code: code),
                                         context: context,
                                         store: store)
                            .navigationTransition(.zoom(sourceID: code,
                                                        in: homeReliefTransition))
                    }
                    .navigationDestination(for: IncomeRoute.self) { _ in
                        IncomeView(model: income)
                    }
                    .navigationDestination(for: EntryHistoryRoute.self) { route in
                        EntryHistoryView(store: store,
                                         year: context.year,
                                         restrictedTo: route.restrictedTo)
                    }
                    .navigationDestination(for: SettingsRoute.self) { _ in
                        SettingsView(context: context, store: store)
                    }
                    .navigationDestination(for: CompareRoute.self) { _ in
                        CompareView(model: CompareViewModel(store: store,
                                                            loader: BundledRuleSetLoader(),
                                                            baselineYear: context.year))
                    }
                    .navigationDestination(for: EntryRoute.self) { route in
                        EntryEditorView(
                            model: EntryEditorViewModel(context: context, store: store,
                                                        editing: route.entryID),
                            presentation: .pushed,
                            onSaved: handleSaved,
                            onDeleted: handleDeleted)
                    }
                    .navigationDestination(for: PrefilledEntryRoute.self) { route in
                        EntryEditorView(
                            model: prefilledEditor(for: route),
                            presentation: .pushed,
                            onSaved: handleSaved,
                            onDeleted: handleDeleted)
                    }
                    .toolbar {
                        ToolbarItem(placement: .principal) { yearMenu(canCompare: true) }
                        ToolbarItem(placement: .topBarLeading) {
                            NavigationLink(value: SettingsRoute()) {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel("Settings")
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
            .tag(Tab.home)

            NavigationStack {
                ReliefsListView(model: ReliefsListViewModel(context: context),
                                namespace: reliefTransition)
                    .navigationDestination(for: ReliefCode.self) { code in
                        ReliefDetailView(model: ReliefDetailViewModel(context: context,
                                                                      store: store,
                                                                      code: code),
                                         context: context,
                                         store: store)
                            .navigationTransition(.zoom(sourceID: code, in: reliefTransition))
                    }
                    .toolbar { ToolbarItem(placement: .principal) { yearMenu(canCompare: false) } }
            }
            .tabItem { Label("Reliefs", systemImage: "list.bullet.rectangle") }
            .tag(Tab.reliefs)

            NavigationStack {
                DocumentsView(model: documents)
                    .toolbar { ToolbarItem(placement: .principal) { yearMenu(canCompare: false) } }
                    .navigationDestination(for: EntryRoute.self) { route in
                        EntryEditorView(
                            model: EntryEditorViewModel(context: context, store: store,
                                                        editing: route.entryID),
                            presentation: .pushed,
                            onSaved: handleSaved,
                            onDeleted: handleDeleted)
                    }
            }
            .tabItem { Label("Docs", systemImage: "doc.text") }
            .tag(Tab.docs)

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
                              await documents.refresh()
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
        // Documents copies out of `context.result` exactly as Home does, so it needs
        // telling to copy again for exactly the same reason. Saving an entry changes
        // which claims are missing a document — often the very entry just saved — and
        // without this the Docs tab kept the count and the rows it had at launch.
        Task { await home.refresh(); await documents.refresh() }
    }

    /// An editor for a brand-new entry that already holds a relief and a figure.
    ///
    /// The prefill is applied at construction, before the destination view hands the model
    /// to its `@State` and its `.task` calls `load()`. That order is what makes it stick:
    /// `load()` only assigns the code and the amount when it opened against an existing
    /// entry, and this one has none.
    private func prefilledEditor(for route: PrefilledEntryRoute) -> EntryEditorViewModel {
        let model = EntryEditorViewModel(context: context, store: store, editing: nil)
        model.prefill(code: route.code, amount: route.amount)
        return model
    }

    private func handleDeleted(_ model: EntryEditorViewModel) {
        lastDeleted = model
        showUndo = true
        Task { await home.refresh(); await documents.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch context.status {
        case .idle, .loading:
            ProgressView()
        case .ready:
            HomeView(model: home,
                     // The claims and their missing documents live on the Docs tab, and
                     // the full list on the Reliefs tab, so these switch tabs rather than
                     // pushing second copies of those screens into Home's stack.
                     onShowDocuments: { selectedTab = .docs },
                     onShowAllReliefs: { selectedTab = .reliefs },
                     namespace: homeReliefTransition)
        case .unavailable(let message):
            // The user's entries still exist. Saying so matters — a blank screen here
            // reads as data loss.
            ContentUnavailableView("No rules for \(String(context.year))",
                                   systemImage: "calendar.badge.exclamationmark",
                                   description: Text(message))
        }
    }
}
