import Testing
import Foundation
import SwiftData
@testable import TaxData

/// Walks a `Schema` and reports every property that would break CloudKit mirroring.
///
/// Spec §5 states the three rules as a convention. A convention is one distracted commit
/// from being false, and the failure mode is not a compile error — it is a container that
/// refuses to open on a user's device after the app has shipped. So it is a test, and
/// every task that adds a `@Model` type re-runs it.
enum SchemaInvariants {

    static func violations(in schema: Schema) -> [String] {
        var problems: [String] = []
        for entity in schema.entities.sorted(by: { $0.name < $1.name }) {
            for attribute in entity.attributes.sorted(by: { $0.name < $1.name }) {
                if attribute.isUnique {
                    problems.append("\(entity.name).\(attribute.name): CloudKit forbids unique constraints")
                }
                if !attribute.isOptional && attribute.defaultValue == nil {
                    problems.append("\(entity.name).\(attribute.name): non-optional with no default")
                }
            }
            for relationship in entity.relationships.sorted(by: { $0.name < $1.name }) {
                if !relationship.isOptional {
                    problems.append("\(entity.name).\(relationship.name): relationship must be optional")
                }
            }
        }
        return problems
    }
}

@Suite("Schema invariants") struct SchemaInvariantTests {

    /// The shipped schema is the single source of truth. A model that is not in
    /// `SchemaV1.models` does not exist as far as the container is concerned, so testing
    /// any other list would test something the app never opens.
    static let allModels: [any PersistentModel.Type] = SchemaV1.models

    @Test("every model is CloudKit-mirroring-safe")
    func modelsAreMirroringSafe() {
        let problems = SchemaInvariants.violations(in: Schema(Self.allModels))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Proves the harness is not vacuous. A deliberately malformed model must be caught.
    @Test("the harness detects a non-optional relationship and a missing default")
    func harnessIsNotVacuous() {
        let problems = SchemaInvariants.violations(in: Schema([BadModel.self, BadParent.self]))
        #expect(problems.contains { $0.contains("BadModel.noDefault") })
        #expect(problems.contains { $0.contains("BadParent.children") })
    }
}

@Model final class BadModel {
    var noDefault: String
    var parent: BadParent?
    init(noDefault: String) { self.noDefault = noDefault }
}

@Model final class BadParent {
    var label: String = ""
    @Relationship(inverse: \BadModel.parent) var children: [BadModel] = []
    init() {}
}
