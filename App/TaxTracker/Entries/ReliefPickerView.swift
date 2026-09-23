import SwiftUI
import TaxKit
import TaxPresentation

/// Choosing which relief an entry belongs to.
///
/// A plain `Picker` here meant scrolling two dozen reliefs with no way to search, on the
/// one screen the app exists to make quick — logging a receipt. Someone who knows they
/// want SSPN had to find SSPN.
///
/// It also showed nothing but names. Which relief a receipt belongs to is not always
/// obvious — "Lifestyle" and "Lifestyle — sports" are a genuine question, and so are the
/// three medical ones — so each row carries LHDN's own description underneath, which is
/// what answers it.
struct ReliefPickerView: View {

    let options: [ReliefOption]
    /// Read off the receipt. Shown first, never selected — the user still chooses.
    var suggested: [ReliefCode] = []
    @Binding var selection: ReliefCode?

    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if !suggestedMatches.isEmpty {
                Section("Suggested from the receipt") {
                    ForEach(suggestedMatches) { row($0) }
                }
                Section("All reliefs") {
                    ForEach(matches) { row($0) }
                }
            } else {
                ForEach(matches) { row($0) }
            }
        }
        .navigationTitle("Choose a relief")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search reliefs")
        .overlay {
            if matches.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private func row(_ option: ReliefOption) -> some View {
        Button {
            selection = option.code
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ReliefCopy.shortName(for: option.code, fullName: option.name))
                        .foregroundStyle(.primary)
                    // LHDN's own wording, which is what says whether this receipt
                    // belongs here. Two lines is enough to disambiguate without
                    // turning the list into a wall.
                    //
                    // Omitted where the two are the same string: "Breastfeeding
                    // equipment" above "Breastfeeding equipment" is noise, and a
                    // few reliefs are already short enough to need no shortening.
                    let full = option.name
                    if full != ReliefCopy.shortName(for: option.code, fullName: full) {
                        Text(full)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if selection == option.code {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Matches the short name, LHDN's full name and the code, the same three the Reliefs
    /// list searches. A user who read "Serious medical" on one screen and types it here
    /// should not be told there is no such relief.
    private var matches: [ReliefOption] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return options }
        return options.filter { option in
            ReliefCopy.shortName(for: option.code, fullName: option.name)
                .lowercased().contains(needle)
                || option.name.lowercased().contains(needle)
                || option.code.rawValue.lowercased().contains(needle)
        }
    }

    /// In the suggester's order, and only those that are both offered here and matching
    /// the search. A suggestion the list cannot show is not shown.
    private var suggestedMatches: [ReliefOption] {
        suggested.compactMap { code in matches.first { $0.code == code } }
    }
}
