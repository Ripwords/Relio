import SwiftUI
import SwiftData
import TaxData

/// How this build stores data, read from `Info.plist` rather than compiled in, so both
/// paths build in every configuration and neither rots unnoticed.
enum StorageMode: String {
    case local
    case cloudKit

    static var current: StorageMode {
        let raw = Bundle.main.object(forInfoDictionaryKey: "RelioStorageMode") as? String
        return StorageMode(rawValue: raw ?? "") ?? .local
    }

    var storage: TaxContainer.Storage {
        switch self {
        case .local: return .localOnly(nil)
        case .cloudKit: return .cloudKit(identifier: nil)
        }
    }
}

@main
struct TaxTrackerApp: App {

    private let container: ModelContainer
    private let store: TaxStore

    init() {
        do {
            container = try TaxContainer.make(StorageMode.current.storage)
        } catch {
            // A container that will not open is not recoverable in-process, and a silent
            // in-memory fallback would let a user enter a year of receipts that are
            // thrown away on quit. Fail loudly instead.
            fatalError("Could not open the data store: \(error)")
        }
        store = TaxStore(modelContainer: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}
