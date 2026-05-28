import Observation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let openComposer = Self("openComposer")
    static let regionThenComposer = Self("regionThenComposer")
}

@MainActor
@Observable
final class HotkeyRegistry {
    private(set) var openComposerAssigned: Bool
    private(set) var regionThenComposerAssigned: Bool

    init() {
        openComposerAssigned = KeyboardShortcuts.getShortcut(for: .openComposer) != nil
        regionThenComposerAssigned = KeyboardShortcuts.getShortcut(for: .regionThenComposer) != nil
    }

    func onOpenComposer(_ action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .openComposer, action: action)
    }

    func onRegionThenComposer(_ action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .regionThenComposer, action: action)
    }

    func isAssigned(_ name: KeyboardShortcuts.Name) -> Bool {
        KeyboardShortcuts.getShortcut(for: name) != nil
    }

    func refreshAssignmentState() {
        openComposerAssigned = isAssigned(.openComposer)
        regionThenComposerAssigned = isAssigned(.regionThenComposer)
    }
}
