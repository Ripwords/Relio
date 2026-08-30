import Testing
import Foundation
import SwiftData
import TaxKit
@testable import TaxData

@Suite("Nationality accessor") struct NationalityAccessorTests {

    @Test("a raw value no case matches reads as nil rather than trapping")
    func unreadableRawDegradesToNil() {
        let row = UserPreferences()
        // CloudKit writes this column, and an older build of the enum is one schema
        // migration away from being asked to read a case it has never heard of.
        row.nationalityRaw = "resident_of_mars"
        #expect(row.nationality == nil)
    }

    @Test("every case round-trips through the raw column")
    func everyCaseRoundTrips() {
        for nationality in NationalityClass.allCases {
            let row = UserPreferences()
            row.nationality = nationality
            #expect(row.nationality == nationality)
            #expect(row.nationalityRaw == nationality.rawValue)
        }
    }

    @Test("an unwritten column reads as not asked yet")
    func nilRawIsNil() {
        let row = UserPreferences()
        #expect(row.nationalityRaw == nil)
        #expect(row.nationality == nil)

        row.nationality = .malaysianCitizen
        row.nationality = nil
        #expect(row.nationalityRaw == nil)
    }
}
