import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

struct RootView: View {

    let store: TaxStore
    @State private var context: YearContext
    @State private var home: HomeViewModel

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
                    .navigationTitle("YA \(String(context.year))")
                    .navigationBarTitleDisplayMode(.inline)
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
        .task {
            await context.load()
            await home.refresh()
        }
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
