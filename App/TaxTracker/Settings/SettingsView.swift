import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

/// Spec §11 has put a gear in the toolbar since the first draft and nothing ever built
/// one. Everything onboarding asked for was therefore a one-time write: skip the welcome
/// flow, or answer it wrongly, and there was no screen anywhere in the app that could
/// change a single one of those facts again.
///
/// It also gives the rulebook's provenance somewhere to live. Spec §13 names a stale
/// rulebook as a top risk and says `verifiedOn` is surfaced in-app; until now it was
/// surfaced nowhere.
struct SettingsView: View {

    let context: YearContext
    let store: TaxStore

    @State private var isEditingHousehold = false
    @State private var isEditingContributor = false

    var body: some View {
        List {
            Section {
                // Rows, not links. They open a sheet rather than pushing, so they take no
                // chevron — but tinting them blue made them read as web links sitting
                // above two rows that look like settings and behave the same way.
                sheetRow("Household and eligibility", systemImage: "person.text.rectangle") {
                    isEditingHousehold = true
                }
                sheetRow("Date of birth and nationality", systemImage: "calendar") {
                    isEditingContributor = true
                }
            } header: {
                Text("About you")
            } footer: {
                Text("These decide which reliefs apply to you and which statutory contribution rates Relio can prove.")
            }

            Section("Your money") {
                NavigationLink(value: IncomeRoute()) {
                    Label("Income", systemImage: "banknote")
                }
                NavigationLink(value: EntryHistoryRoute()) {
                    Label("Input history", systemImage: "clock.arrow.circlepath")
                }
            }

            if let ruleSet = context.ruleSet {
                Section {
                    LabeledContent("Year of assessment", value: "YA \(String(ruleSet.yearOfAssessment))")
                    LabeledContent("Rulebook revision", value: String(ruleSet.revision))
                    // Spec §13: a rulebook goes stale after a Budget, and the mitigation
                    // is that the user can see how old this one is.
                    if let verified = ruleSet.verifiedOnDate {
                        LabeledContent("Transcribed from LHDN") {
                            Text(verified, style: .date)
                        }
                    }
                    Link("hasil.gov.my", destination: ruleSet.sourceURL)
                } header: {
                    Text("Where the numbers come from")
                } footer: {
                    Text("Every figure Relio shows is an estimate. Tax rules change and transcription can err — verify with LHDN before you file, and consult a licensed tax agent for anything that matters.")
                }
            }

            Section {
                LabeledContent("Storage", value: storageDescription)
            } footer: {
                Text("Relio has no account and no server. Your data stays on your devices.")
            }
        }
        .navigationTitle("Settings")
        #if DEBUG
        // Both sheets are presented from this view's own state, so RootView's
        // `-relio-screen` switch cannot reach them.
        .task {
            switch DemoHarness.screen {
            case "settings-household": isEditingHousehold = true
            case "settings-contributor": isEditingContributor = true
            default: break
            }
        }
        #endif
        .sheet(isPresented: $isEditingHousehold) {
            ProfileQuestionsSheet(
                model: ProfileQuestionsViewModel(context: context,
                                                 store: store,
                                                 questions: ProfileQuestion.allCases,
                                                 // A profile to edit, not a prompt to
                                                 // clear — see `requiresEveryAnswer`.
                                                 requiresEveryAnswer: false),
                title: "Household") {}
        }
        .sheet(isPresented: $isEditingContributor) {
            ContributionQuestionsSheet(
                model: ContributionQuestionsViewModel(
                    store: store,
                    questions: [.contribution(.dateOfBirth), .contribution(.nationality)]),
                title: "Date of birth and nationality")
        }
    }

    private func sheetRow(_ title: String,
                          systemImage: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Named honestly rather than as a promise. iCloud mirroring is built but has never
    /// been verified end to end on two signed-in devices, and this build runs local-only.
    private var storageDescription: String {
        switch StorageMode.current {
        case .local: "This device only"
        case .cloudKit: "This device and your iCloud"
        }
    }
}
