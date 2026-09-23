import Testing
@testable import TaxCapture

/// The QR on a MyInvois e-invoice is a validation link, `{portal}/{uuid}/share/{longId}`,
/// and nothing else. Offline, the document ID is all it gives — spec §2 and §4.
///
/// MyInvois IDs are not RFC 4122 UUIDs. LHDN's own API example is `F9D425P6DS7D8IU`.
@Suite("The MyInvois QR link") struct MyInvoisLinkTests {

    static let longId = "RZ6FQYX9J1G6V3K8H2M4T7W0C5B9N1P3"

    @Test("production and preprod links are accepted")
    func acceptsBothPortals() throws {
        let production = try #require(MyInvoisLink(
            "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/\(Self.longId)"))
        #expect(production.uuid == "F9D425P6DS7D8IU")
        #expect(production.longId == Self.longId)
        #expect(MyInvoisLink(
            "https://preprod.myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/\(Self.longId)") != nil)
    }

    @Test("the host is case-insensitive and surrounding whitespace is ignored")
    func tolerant() {
        #expect(MyInvoisLink(
            "  https://MyInvois.Hasil.gov.my/F9D425P6DS7D8IU/share/\(Self.longId)\n")?.uuid
            == "F9D425P6DS7D8IU")
    }

    @Test("anything else is not a MyInvois link", arguments: [
        "http://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://myinvois.hasil.gov.my.example.com/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://example.com/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4/extra",
        "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4/",
        "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/view/RZ6FQYX9J1G6V3K8H2M4",
        "https://myinvois.hasil.gov.my/F9D4-25P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4?x=1",
        "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4#top",
        "https://myinvois.hasil.gov.my:8443/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://someone@myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://myinvois.hasil.gov.my/SHORT/share/RZ6FQYX9J1G6V3K8H2M4",
        "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/SHORT",
        "WIFI:S:CafeGuest;T:WPA;P:secret;;",
        "",
    ])
    func rejects(payload: String) {
        #expect(MyInvoisLink(payload) == nil)
    }
}
