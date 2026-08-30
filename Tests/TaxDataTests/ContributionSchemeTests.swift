import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Contribution scheme") struct ContributionSchemeTests {

    @Test("each scheme names the relief its floor is evidence for")
    func reliefCodes() {
        #expect(ContributionScheme.employeesProvidentFund.reliefCode == .epfContribution)
        #expect(ContributionScheme.socialSecurity.reliefCode == .socsoEis)
    }

    @Test("SOCSO and EIS are one scheme, not two")
    func socialSecurityIsOneScheme() {
        // Both Acts are relieved under a single paragraph and a single figure, so two
        // schemes would produce two floors that only ever get added back up.
        #expect(ContributionScheme.allCases.count == 2)
    }

    @Test("a profile starts with both facts unanswered")
    func profileDefaults() {
        // Every user on every device today. Neither fact has ever been asked, and `nil`
        // must stay `nil` rather than defaulting to the commonest answer.
        let profile = ContributorProfile()
        #expect(profile.dateOfBirth == nil)
        #expect(profile.nationality == nil)
    }

    @Test("a source's answer for a scheme stays three-valued")
    func schemeReadsItsOwnFlag() {
        let asked = IncomeSourceSnapshot(deductsEPF: true, deductsSOCSO: false)
        #expect(ContributionScheme.employeesProvidentFund.deduction(in: asked) == true)
        #expect(ContributionScheme.socialSecurity.deduction(in: asked) == false)

        let unasked = IncomeSourceSnapshot()
        #expect(ContributionScheme.employeesProvidentFund.deduction(in: unasked) == nil)
        #expect(ContributionScheme.socialSecurity.deduction(in: unasked) == nil)
    }
}
