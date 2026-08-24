import SwiftUI
import TaxData

struct RootView: View {
    let store: TaxStore

    var body: some View {
        VStack(spacing: 12) {
            Text("Relio")
                .font(.largeTitle.bold())
            Text("Storage: \(StorageMode.current.rawValue)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
