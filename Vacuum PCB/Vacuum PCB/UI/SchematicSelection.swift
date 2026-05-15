import Foundation

/// Multi-selection on the schematic canvas.
///
/// Holds any number of components at once (so a marquee can grab a subcircuit)
/// plus an optional single net. Pins aren't a "selection" — the in-progress
/// net-drawing interaction tracks the first-clicked pin separately in
/// `NetDrawState`.
struct SchematicSelection: Hashable {
    var components: Set<UUID> = []
    var net: UUID? = nil

    static let none = SchematicSelection()

    var isEmpty: Bool { components.isEmpty && net == nil }

    /// Single-component case: lets the inspector strip and rename UI work as
    /// before when exactly one component is selected.
    var singleComponent: UUID? {
        guard net == nil, components.count == 1 else { return nil }
        return components.first
    }

    /// Drives the hidden-Button keyboardShortcut wiring's `.disabled` flag,
    /// so the Delete shortcut yields to focused TextFields when nothing is
    /// selected.
    var isDeletable: Bool { !isEmpty }

    func contains(component id: UUID) -> Bool { components.contains(id) }
    func contains(net id: UUID) -> Bool { net == id }

    static func component(_ id: UUID) -> SchematicSelection {
        SchematicSelection(components: [id])
    }

    static func net(_ id: UUID) -> SchematicSelection {
        SchematicSelection(net: id)
    }
}

/// State machine for the click-pin → click-pin net-drawing interaction.
enum NetDrawState: Hashable {
    case idle
    case awaitingSecondPin(firstPin: PinRef)
}

/// Shared state for a multi-component drag in the schematic canvas. Lives on
/// SchematicCanvasView as @State; the grabbed ComponentNodeView writes into
/// it (translation in screen pts) and every other participant reads it via
/// a binding to render the same offset, so the whole group follows one
/// cursor.
struct SchematicMultiDrag: Equatable {
    var participants: Set<UUID>
    var originals: [UUID: Point]
    var translation: CGSize
}
