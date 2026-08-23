import Testing
import Foundation
@testable import TaxKit

@Suite("Money.split") struct MoneySplitTests {

    @Test("an even split is exact")
    func evenSplit() {
        let parts = Money(ringgit: 2000).split(into: 2)
        #expect(parts.map(\.sen) == [100_000, 100_000])
    }

    @Test("an uneven split distributes the remainder to the earliest parts")
    func unevenSplit() {
        // RM 2,500.00 into three is 833.34 / 833.33 / 833.33
        let parts = Money(ringgit: 2500).split(into: 3)
        #expect(parts.map(\.sen) == [83_334, 83_333, 83_333])
    }

    @Test("parts always sum back to the original, for every divisor up to 50")
    func splitAlwaysSums() {
        for sen in [0, 1, 7, 99, 100, 250_000, 999_999, 1_000_003] {
            for n in 1...50 {
                let original = Money(sen: sen)
                let total = original.split(into: n).reduce(Money.zero, +)
                #expect(total == original, "sen=\(sen) n=\(n)")
            }
        }
    }

    @Test("weighted splits honour the weights and still sum exactly")
    func weightedSplit() {
        let parts = Money(sen: 1000).split(weights: [1, 3])
        #expect(parts.map(\.sen) == [250, 750])

        let awkward = Money(sen: 100).split(weights: [1, 1, 1])
        #expect(awkward.map(\.sen) == [34, 33, 33])
        #expect(awkward.reduce(Money.zero, +).sen == 100)
    }

    @Test("negative amounts split without losing a sen")
    func negativeSplit() {
        let parts = Money(sen: -100).split(into: 3)
        #expect(parts.reduce(Money.zero, +).sen == -100)
        #expect(parts.map(\.sen) == [-34, -33, -33])
    }

    @Test("a single part returns the whole")
    func singlePart() {
        #expect(Money(sen: 777).split(into: 1).map(\.sen) == [777])
    }
}
