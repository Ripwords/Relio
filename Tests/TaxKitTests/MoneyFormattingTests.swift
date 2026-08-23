import Testing
import Foundation
@testable import TaxKit

@Suite("Money formatting") struct MoneyFormattingTests {

    @Test("formats with an RM prefix, comma grouping and two decimals")
    func standardFormat() {
        #expect(Money(sen: 250_000).formatted() == "RM 2,500.00")
        #expect(Money(sen: 15_200).formatted()  == "RM 152.00")
        #expect(Money(sen: 5).formatted()       == "RM 0.05")
        #expect(Money.zero.formatted()          == "RM 0.00")
    }

    @Test("groups thousands and millions")
    func grouping() {
        #expect(Money(sen: 100_000_000).formatted() == "RM 1,000,000.00")
    }

    @Test("negatives put the sign before the prefix")
    func negatives() {
        #expect(Money(sen: -15_200).formatted() == "-RM 152.00")
    }

    @Test("the compact form drops the sen")
    func compact() {
        #expect(Money(sen: 250_000).formattedCompact() == "RM 2,500")
        #expect(Money(sen: 250_050).formattedCompact() == "RM 2,501")   // rounds half-up
        #expect(Money(sen: -250_000).formattedCompact() == "-RM 2,500")
    }
}
