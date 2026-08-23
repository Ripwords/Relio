import Foundation

/// TaxKit's own resource bundle.
///
/// `Bundle.module` is resolved per target, so the same expression written inside a test
/// file names the test bundle instead. Everything that reads a shipped rulebook — the
/// loader and the integrity tests alike — goes through this one accessor, so they can
/// never end up reading different copies.
enum RuleBundle {
    static var current: Bundle { .module }
}
