import SwiftUI
import TaxKit
import TaxData
import TaxPresentation
import TaxCapture

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
    /// The relief the iPad's detail column is showing. Unused on iPhone, where a relief
    /// is pushed onto a stack instead.
    @State private var selectedRelief: ReliefCode?
    @State private var columns = NavigationSplitViewVisibility.all
    /// Ties a relief row to the detail screen it opens. See `ReliefsListView.namespace`.
    @Namespace private var reliefTransition
    @Namespace private var homeReliefTransition
    /// The year menu pushes Income, and a menu item cannot be a `NavigationLink`, so the
    /// stack needs a path to append to.
    @State private var path = NavigationPath()
    @State private var editingEntry: EntryEditorViewModel?
    /// Home's "Scan a receipt": which picker is open.
    @State private var captureSource: ReceiptSource?
    /// A receipt that could not be decoded or saved. Shown as an alert, since no editor
    /// is open yet to show it in.
    @State private var captureError: String?
    @State private var showUndo = false
    @State private var lastDeleted: EntryEditorViewModel?
    // `nil` means the preference has not been read yet. Defaulting this to "show
    // onboarding" would flash the welcome screen at every returning user on every
    // launch.
    @State private var needsOnboarding: Bool?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
    private enum Tab: Hashable, CaseIterable {
        case home, reliefs, docs

        var title: String {
            switch self {
            case .home: "Home"
            case .reliefs: "Reliefs"
            case .docs: "Docs"
            }
        }

        var symbol: String {
            switch self {
            case .home: "house"
            case .reliefs: "list.bullet.rectangle"
            case .docs: "doc.text"
            }
        }
    }

    var body: some View {
        Group {
            if needsOnboarding == true {
                OnboardingView(model: OnboardingViewModel(store: store, year: context.year)) {
                    needsOnboarding = false
                    Task { await context.reload(); await home.refresh() }
                }
            } else if needsOnboarding == false {
                // Spec §11 draws iPhone as three tabs over the content and iPad as a
                // sidebar, a list and a detail column side by side. The size class is the
                // honest test rather than the idiom: an iPad in a narrow split window is a
                // compact width and wants the tab bar too.
                if horizontalSizeClass == .compact {
                    tabs
                } else {
                    splitView
                }
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
            if let delay = DemoHarness.delay {
                try? await Task.sleep(for: .seconds(delay))
            }
            // Needs a fetch, so it cannot live in the synchronous switch below. Opening a
            // *saved* entry is the only way to see the documents section, which is hidden
            // until an entry has an identity to attach to.
            if DemoHarness.wantsAttachment,
               let entry = try? await store.entryDrafts(forYear: context.year).first,
               let data = SampleReceipt.jpeg(),
               case .read(let reading) = await CapturePipeline.read(.image(data),
                                                                    ruleSet: context.ruleSet),
               let files = try? DocumentFileStore() {
                let editor = EntryEditorViewModel(context: context, store: store,
                                                  editing: entry.id)
                await editor.load()
                _ = await editor.attach(reading, files: files)
                await home.refresh()
                await documents.refresh()
            }
            if DemoHarness.screen == "entry-existing",
               let first = try? await store.entryDrafts(forYear: context.year).first {
                path.append(EntryRoute(entryID: first.id))
            }
            openDemoScreen()
            // Scan first, through the same pipeline and `openScanned` a real scan takes.
            // Only the camera is skipped, which the simulator does not have.
            if DemoHarness.wantsScan,
               let data = SampleReceipt.jpeg(qr: DemoHarness.scanQR),
               case .read(let reading) = await CapturePipeline.read(.image(data),
                                                                    ruleSet: context.ruleSet) {
                await openScanned(reading)
            }
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
        case "dependents", "dependent-editor", "dependent-new":
            path.append(DependentsRoute())
        case "compare": path.append(CompareRoute())
        case "summary": path.append(TaxSummaryRoute())
        case "reliefs": selectedTab = .reliefs
        case "income", "income-add-source", "income-add-change", "income-edit-record":
            path.append(IncomeRoute())
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
            let code = ReliefCode(String(name.dropFirst("relief:".count)))
            // Two layouts, two destinations. On iPhone a relief is pushed onto the stack;
            // on iPad it fills the split view's detail column, which the path does not
            // feed.
            if horizontalSizeClass == .compact {
                path.append(code)
            } else {
                selectedTab = .reliefs
                selectedRelief = code
            }
        case "scan-picker":
            break   // `-relio-scan` opens the editor; the editor opens its picker.
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

    /// Spec §11's iPad shape: a sidebar of destinations, the chosen one's list, and the
    /// relief detail beside it rather than on top of it.
    ///
    /// The detail column is shared by every tab. Selecting a relief from the Reliefs list
    /// or from Home's opportunities fills the same column, which is the point of the
    /// layout — the list stays visible and the selection stays highlighted while the
    /// figures are read.
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            // Buttons with an explicit selected background, not `List(selection:)`:
            // every single-selection `List` initialiser taking a `Binding<Value?>` is
            // unavailable on iOS in this SDK.
            List {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack {
                            Label(tab.title, systemImage: tab.symbol)
                                .foregroundStyle(selectedTab == tab ? Color.accentColor : .primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selectedTab == tab
                                       ? Color.accentColor.opacity(0.12)
                                       : Color.clear)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .navigationTitle("Relio")
            .toolbar {
                ToolbarItem(placement: .principal) { yearMenu(canCompare: true) }
            }
        } content: {
            NavigationStack(path: $path) {
                splitContent
                    .navigationDestination(for: IncomeRoute.self) { _ in IncomeView(model: income) }
                    .navigationDestination(for: EntryHistoryRoute.self) { route in
                        EntryHistoryView(store: store, year: context.year,
                                         restrictedTo: route.restrictedTo)
                    }
                    .navigationDestination(for: SettingsRoute.self) { _ in
                        SettingsView(context: context, store: store) {
                            Task { await home.refresh(); await documents.refresh() }
                        }
                    }
                    .navigationDestination(for: DependentsRoute.self) { _ in
                        DependentsView(model: DependentsViewModel(context: context,
                                                                  store: store)) {
                            Task { await home.refresh(); await documents.refresh() }
                        }
                    }
                    .navigationDestination(for: CompareRoute.self) { _ in
                        CompareView(model: CompareViewModel(store: store,
                                                            loader: BundledRuleSetLoader(),
                                                            baselineYear: context.year))
                    }
                    .navigationDestination(for: TaxSummaryRoute.self) { _ in
                        if let result = context.result, let summary = TaxSummary(result) {
                            TaxSummaryView(summary: summary, year: context.year)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            NavigationLink(value: SettingsRoute()) {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel("Settings")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            ReceiptSourceMenu(source: $captureSource)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                editingEntry = EntryEditorViewModel(context: context,
                                                                    store: store, editing: nil)
                            } label: { Image(systemName: "plus") }
                                .accessibilityLabel("Add an entry")
                        }
                    }
            }
        } detail: {
            NavigationStack {
                if let selectedRelief {
                    ReliefDetailView(model: ReliefDetailViewModel(context: context,
                                                                  store: store,
                                                                  code: selectedRelief),
                                     context: context,
                                     store: store)
                    .id(selectedRelief)
                } else {
                    // Not a failure — the third column simply has nothing chosen yet, and
                    // saying so beats an empty panel the reader has to interpret.
                    ContentUnavailableView("No relief chosen",
                                           systemImage: "hand.tap",
                                           description: Text("Pick one from the list to see its cap, what you have claimed and what LHDN asks for."))
                }
            }
        }
        .sheet(item: $editingEntry) { model in
            EntryEditorView(model: model, presentation: .sheet,
                            onSaved: handleSaved, onDeleted: handleDeleted)
        }
        .receiptCapture(source: $captureSource,
                        ruleSet: context.ruleSet,
                        onRead: { reading in await openScanned(reading) },
                        onError: { captureError = $0 })
        .alert(captureError ?? "",
               isPresented: Binding(get: { captureError != nil },
                                    set: { if !$0 { captureError = nil } })) {
            Button("OK", role: .cancel) {}
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
                .padding(.bottom, 24)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: showUndo)
    }

    /// The middle column: whichever destination the sidebar has selected.
    @ViewBuilder
    private var splitContent: some View {
        switch selectedTab {
        case .home:
            content
        case .reliefs:
            ReliefsListView(model: ReliefsListViewModel(context: context),
                            namespace: reliefTransition,
                            selection: $selectedRelief)
        case .docs:
            DocumentsView(model: documents)
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
                        SettingsView(context: context, store: store) {
                            Task { await home.refresh(); await documents.refresh() }
                        }
                    }
                    .navigationDestination(for: DependentsRoute.self) { _ in
                        DependentsView(model: DependentsViewModel(context: context,
                                                                  store: store)) {
                            // A child changes which reliefs are claimable, so every screen
                            // that copies out of the evaluation has to copy again.
                            Task { await home.refresh(); await documents.refresh() }
                        }
                    }
                    .navigationDestination(for: TaxSummaryRoute.self) { _ in
                        if let result = context.result, let summary = TaxSummary(result) {
                            TaxSummaryView(summary: summary, year: context.year)
                        } else {
                            // Reachable only from a headline that is showing relief rather
                            // than tax, which is the no-income case.
                            ContentUnavailableView(
                                "No income recorded",
                                systemImage: "banknote",
                                description: Text("Add what you earn and Relio can work out the tax as well as the relief."))
                        }
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
                            ReceiptSourceMenu(source: $captureSource)
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
        .receiptCapture(source: $captureSource,
                        ruleSet: context.ruleSet,
                        onRead: { reading in await openScanned(reading) },
                        onError: { captureError = $0 })
        .alert(captureError ?? "",
               isPresented: Binding(get: { captureError != nil },
                                    set: { if !$0 { captureError = nil } })) {
            Button("OK", role: .cancel) {}
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

    /// Scan first (spec §5): a new-entry editor holding what the receipt said, its file
    /// already written and waiting for Save.
    private func openScanned(_ reading: ReceiptReading) async {
        let model = EntryEditorViewModel(context: context, store: store, editing: nil)
        guard let files = try? DocumentFileStore(),
              await model.prefill(from: reading, files: files) else {
            captureError = "Relio could not save that file. Try again."
            return
        }
        editingEntry = model
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
