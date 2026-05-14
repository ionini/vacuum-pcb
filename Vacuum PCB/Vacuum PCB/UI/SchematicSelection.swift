import Foundation

/// What the user has selected in the schematic editor. Top-level so DocumentView
/// can own the state and share it with the inspector strip.
enum SchematicSelection: Hashable {
    case none
    case component(UUID)
    case net(UUID)
    case pin(componentId: UUID, pinKey: String)

    var componentId: UUID? {
        if case let .component(id) = self { return id }
        return nil
    }

    var netId: UUID? {
        if case let .net(id) = self { return id }
        return nil
    }
}

/// State machine for the click-pin → click-pin net-drawing interaction.
enum NetDrawState: Hashable {
    case idle
    case awaitingSecondPin(firstPin: PinRef)
}
