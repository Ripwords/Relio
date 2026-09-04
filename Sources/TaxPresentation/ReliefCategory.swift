import Foundation
import TaxKit

/// The family a relief belongs to.
///
/// LHDN publishes a flat list of thirty-two, which is why the app read as ungrouped: no
/// screen could say what any relief had to do with any other. The rulebook has no notion
/// of a family and should not gain one — nothing in `Resources/Rules/` should carry a
/// judgement LHDN never made — so the grouping is editorial and lives here beside the
/// short names, where `swift test` can reach it.
///
/// Six families, ordered the way a person thinks about their own money rather than the
/// way the rulebook lists it: themselves first, then who depends on them, then what they
/// spend it on.
public enum ReliefCategory: String, CaseIterable, Hashable, Sendable {
    case you
    case children
    case health
    case learning
    case living
    case saving

    public var title: String {
        switch self {
        case .you: "You and your spouse"
        case .children: "Children"
        case .health: "Health"
        case .learning: "Learning"
        case .living: "Home and living"
        case .saving: "Saving and cover"
        }
    }

    /// Shown beside the title in section headers. A family the reader can recognise
    /// without reading is one they can skip when it is not the one they want.
    public var symbol: String {
        switch self {
        case .you: "person"
        case .children: "figure.2.and.child.holdinghands"
        case .health: "heart"
        case .learning: "graduationcap"
        case .living: "house"
        case .saving: "banknote"
        }
    }

    /// Where each family's colour comes from, as a light/dark pair of sRGB components.
    ///
    /// Drawn from Malaysian ringgit notes rather than picked to look nice: the RM1 blue,
    /// the RM10 red, the RM50 turquoise, the RM100 purple. It is the one palette a
    /// Malaysian taxpayer already associates with money, which is what makes it a choice
    /// about this app rather than a set of pleasant hues.
    ///
    /// Held here rather than in the view layer because the mapping from family to hue is a
    /// decision, not a rendering detail, and this is where the families are defined. The
    /// `Color` itself is built in the app, which is the only target that can.
    public var tint: (light: (red: Double, green: Double, blue: Double),
                      dark: (red: Double, green: Double, blue: Double)) {
        switch self {
        // RM1 blue.
        case .you: ((0.145, 0.388, 0.659), (0.404, 0.612, 0.855))
        // RM10 red, warmed so it reads as a family rather than an alarm.
        case .children: ((0.788, 0.278, 0.341), (0.925, 0.478, 0.529))
        // RM50 turquoise.
        case .health: ((0.055, 0.518, 0.475), (0.259, 0.729, 0.678))
        // The gold of the RM50's foil band.
        case .learning: ((0.702, 0.475, 0.086), (0.902, 0.678, 0.290))
        // RM20 orange, taken down to a clay.
        case .living: ((0.659, 0.333, 0.212), (0.878, 0.549, 0.412))
        // RM100 purple.
        case .saving: ((0.420, 0.310, 0.659), (0.635, 0.545, 0.867))
        }
    }

    /// The family a relief belongs to, or `nil` for a code no rulebook here ships.
    ///
    /// `ReliefCategoryTests` asserts every generated code lands somewhere, which is the
    /// substitute for exhaustiveness that a string-wrapper `ReliefCode` cannot give.
    public init?(_ code: ReliefCode) {
        guard let category = Self.families[code] else { return nil }
        self = category
    }

    private static let families: [ReliefCode: ReliefCategory] = [
        // The taxpayer and the person they are assessed with.
        .selfAndDependents: .you,
        .spouseAlimony: .you,
        .disabledSelf: .you,
        .disabledSpouse: .you,

        // Everything claimed for a child, including the two that are about caring for one
        // rather than about the child's own circumstances.
        .childUnder18: .children,
        .childPreTertiary: .children,
        .childTertiary: .children,
        .childDisabled: .children,
        .childDisabledTertiary: .children,
        .childcare: .children,
        .breastfeeding: .children,

        // Medical, including the parents' reliefs: a taxpayer looking for what they spent
        // on their mother's treatment looks under health, not under family.
        .medicalSerious: .health,
        .medicalCheckup: .health,
        .medicalDental: .health,
        .medicalVaccination: .health,
        .medicalLearndis: .health,
        .parentsMedical: .health,
        .parentsCheckup: .health,
        .disabledEquipment: .health,

        .educationSelf: .learning,
        .educationUpskill: .learning,
        .sspn: .learning,

        // What the household spends on itself. Lifestyle covers books and devices, which
        // sit closer to living than to learning in how people shop for them.
        .lifestyle: .living,
        .lifestyleSports: .living,
        .evCharging: .living,
        .housingLoanInterest: .living,

        // Money put aside or insured, statutory or voluntary.
        .insuranceLifeEpf: .saving,
        .lifeInsurance: .saving,
        .epfContribution: .saving,
        .prsAnnuity: .saving,
        .insuranceEduMedical: .saving,
        .socsoEis: .saving,
    ]
}
