#if canImport(AppKit)
import SwiftUI

/// Focused-scene actions behind the Edit-menu manufacturing copy/paste pair:
/// the frontmost `DocumentView` publishes them, the menu items call them.
/// `canPaste` mirrors `ManufacturingClipboard.shared.hasContent` (DocumentView
/// observes the clipboard) and is the only thing menu validation needs to
/// diff — the closures are rebuilt on every render but capture only the
/// document binding and the view's state.
struct ManufacturingClipboardActions: Equatable {
    let canPaste: Bool
    let copy: @MainActor () -> Void
    let requestPaste: @MainActor () -> Void

    static func == (a: Self, b: Self) -> Bool { a.canPaste == b.canPaste }
}

struct ManufacturingClipboardActionsKey: FocusedValueKey {
    typealias Value = ManufacturingClipboardActions
}

extension FocusedValues {
    var manufacturingClipboard: ManufacturingClipboardActions? {
        get { self[ManufacturingClipboardActionsKey.self] }
        set { self[ManufacturingClipboardActionsKey.self] = newValue }
    }
}

/// Edit > Copy / Paste Manufacturing Parameters. Sits after the standard
/// pasteboard group, on ⌥⌘C / ⌥⌘V — plain ⌘C / ⌘V are taken by the schematic
/// canvas's own component clipboard (`KeyEventCatcher` claims command-only
/// chords, so the ⌥ variants reach the menu untouched).
struct ManufacturingClipboardCommands: Commands {
    @FocusedValue(\.manufacturingClipboard) private var actions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Manufacturing Parameters") { actions?.copy() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Paste Manufacturing Parameters…") { actions?.requestPaste() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!(actions?.canPaste ?? false))
        }
    }
}
#endif
