import SwiftUI
import TaxKit
import TaxPresentation

struct ReliefDetailView: View {

    @Bindable var model: ReliefDetailViewModel

    var body: some View {
        List {
            if let assessment = model.assessment {
                Section {
                    labelled("Cap", assessment.cap)
                    labelled("Claimed", assessment.claimed)
                    // Both figures, labelled. `claimed` is what the user entered;
                    // `allowed` is what LHDN would permit once caps bind. Showing one
                    // without the other either hides a trim or overstates the claim.
                    labelled("Allowed", assessment.allowed)
                    labelled("Still claimable", assessment.headroom)
                    if let saved = assessment.taxSaved {
                        labelled("Tax saved", saved)
                    }
                }

                if case .needsInfo(let questions) = assessment.eligibility {
                    Section("To claim this") {
                        ForEach(questions, id: \.self) { question in
                            Label(Self.text(for: question), systemImage: "questionmark.circle")
                        }
                    }
                }

                if case .ineligible(let reasons) = assessment.eligibility {
                    Section("Why you cannot claim this") {
                        ForEach(reasons, id: \.self) { reason in
                            Label(reason, systemImage: "xmark.circle")
                        }
                    }
                }

                if !model.subLimits.isEmpty {
                    Section("Within this relief") {
                        ForEach(model.subLimits) { child in
                            NavigationLink(value: child.code) {
                                HStack {
                                    Text(child.name)
                                    Spacer()
                                    MoneyText(amount: child.headroom, font: .subheadline)
                                }
                            }
                        }
                    }
                }

                if !model.requirements.isEmpty {
                    Section("Documents") {
                        ForEach(model.requirements, id: \.kind) { check in
                            Label(Self.text(for: check.kind),
                                  systemImage: check.isSatisfied ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(check.isSatisfied ? Color.primary : Color.orange)
                        }
                    }
                }

                Section("Entries") {
                    if model.entries.isEmpty {
                        Text("Nothing logged for this relief yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.entries) { entry in
                            NavigationLink(value: EntryRoute(entryID: entry.id)) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(entry.vendor.isEmpty ? "Untitled" : entry.vendor)
                                        if entry.needsDocument {
                                            Text("Missing a document")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer()
                                    MoneyText(amount: entry.amount, font: .subheadline)
                                }
                            }
                        }
                    }
                }

                if let url = model.sourceURL {
                    Section {
                        Link("LHDN source", destination: url)
                        if let notes = model.notes {
                            Text(notes).font(.footnote).foregroundStyle(.secondary)
                        }
                    } footer: {
                        // Spec §13: the user must never mistake an estimate for advice.
                        Text("Estimate only. Verify with LHDN before you file.")
                    }
                }
            } else {
                ContentUnavailableView("Relief not found",
                                       systemImage: "questionmark.folder",
                                       description: Text("This relief is not part of the \(String(model.yearOfAssessment)) rulebook."))
            }
        }
        .navigationTitle(model.assessment?.name ?? "Relief")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
    }

    private func labelled(_ title: String, _ amount: Money) -> some View {
        HStack {
            Text(title)
            Spacer()
            MoneyText(amount: amount, font: .body, weight: .medium)
        }
    }

    /// Presentation-only copy for a fact the app still needs to ask about. `ProfileQuestion`
    /// carries no display text of its own (it is a plain `String` enum used as a rulebook
    /// key), so this is the one place that maps a question to what the user reads —
    /// `String(describing:)` would otherwise leak the raw case name ("maritalStatus").
    private static func text(for question: ProfileQuestion) -> String {
        switch question {
        case .maritalStatus: "Marital status"
        case .spouseHasIncome: "Whether your spouse has income"
        case .assessmentType: "How you are assessed"
        case .employmentType: "Employment type"
        case .gender: "Gender"
        case .dependentDetails: "Dependant details"
        case .lastClaimYear: "When you last claimed this"
        case .propertyPrice: "Property price"
        case .disabilityStatus: "Disability status"
        case .spouseDisabilityStatus: "Your spouse's disability status"
        }
    }

    /// Presentation-only copy for a required document kind, for the same reason as
    /// `text(for: ProfileQuestion)` above.
    private static func text(for kind: DocumentKind) -> String {
        switch kind {
        case .officialReceipt: "Official receipt"
        case .taxInvoice: "Tax invoice"
        case .eInvoice: "e-Invoice"
        case .medicalCertificate: "Medical certificate"
        case .referralLetter: "Referral letter"
        case .insuranceStatement: "Insurance statement"
        case .epfStatement: "EPF statement"
        case .bankStatement: "Bank statement"
        case .other: "Other document"
        }
    }
}
