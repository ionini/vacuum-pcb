import SwiftUI

/// One component on the schematic canvas: its symbol, label rename interaction,
/// drag-to-move, and pin click handles. Positioned by its parent.
struct ComponentNodeView: View {
    let component: Component
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection
    @Binding var netDrawState: NetDrawState
    /// Shared multi-drag state owned by SchematicCanvasView. When the user
    /// grabs a member of a multi-selection, the dragged ComponentNodeView
    /// writes the participants + live translation here; every other node
    /// reads it to apply the same offset so the whole group follows
    /// together.
    @Binding var multiDrag: SchematicMultiDrag?
    /// Live single-drag displacement published to the canvas so the net lines
    /// redraw mid-drag. Set only while this node drives a lone drag (group
    /// drags use `multiDrag`); cleared when the drag ends or is cancelled.
    @Binding var liveDragShift: SchematicDragShift?
    /// Bumped by the parent canvas whenever a second finger touches down.
    /// We watch this and abort any single-finger drag in flight so the
    /// component snaps back instead of trailing the user's first finger
    /// during a pan/pinch.
    var dragInvalidation: Int = 0
    /// Forwarded straight to each `PinHandleView` so SchematicCanvasView
    /// can hit-test the drop pin across every component. Receives the
    /// pin's owning component id + pin key plus the drag location in
    /// schematic coords.
    var onPinDragChanged: (PinRef, CGPoint) -> Void = { _, _ in }
    var onPinDragEnded: (PinRef, CGPoint) -> Void = { _, _ in }
    /// Schematic orientation in 90° clockwise quarter-turns. Rotates the
    /// symbol's box, pin handles, and sockets; the label stays upright.
    var rotationQuarterTurns: Int = 0

    @State private var dragOffset: CGSize = .zero
    /// Set when `dragInvalidation` changes during a live drag. The drag
    /// gesture's `.onEnded` reads this and skips committing the move.
    @State private var dragCancelled: Bool = false
    @State private var isRenaming = false
    @State private var renameDraft: String = ""
    /// Timestamp of this node's last plain tap, for hand-rolled double-tap
    /// detection. Per-node `@State`, so a quick tap on *this* component opens
    /// rename while a quick tap moving between two components just reselects.
    @State private var lastTapTime: Date = .distantPast
    @FocusState private var renameFieldFocused: Bool

    /// Scale factor the canvas applies via .scaleEffect. We divide every
    /// `.global`-coord drag translation by this so the offset we render in
    /// the (un-scaled) schematic coord space matches the pixel distance the
    /// user actually dragged — at 2× zoom a 100 px drag should move the
    /// component 50 schematic units, not 100.
    @Environment(\.schematicZoom) private var schematicZoom: Double
    /// When the canvas is locked into pan/zoom mode, our drag gesture is
    /// masked to `.none` so a stray finger landing on this component
    /// during a pinch can't kick off a drag.
    @Environment(\.canvasLocked) private var canvasLocked: Bool

    private var isSelected: Bool {
        selection.contains(component: component.id)
    }

    /// Effective offset applied to this node:
    ///   * If a multi-drag is in flight and this node is participating →
    ///     use the shared translation (other selected nodes follow the grab).
    ///   * Otherwise our own dragOffset (set only when this node IS the
    ///     grabbed one in single-drag mode).
    private var effectiveOffset: CGSize {
        if let multi = multiDrag, multi.participants.contains(component.id) {
            return multi.translation
        }
        return dragOffset
    }

    var body: some View {
        let snapshots = document.circuit.librarySnapshots
        let m = ComponentSymbolMetrics.metrics(for: component, snapshots: snapshots)
            .rotated(by: rotationQuarterTurns)
        return ZStack {
            ComponentSymbolView(component: component, isSelected: isSelected,
                                rotationQuarterTurns: rotationQuarterTurns)
                // A single tap gesture only — it fires immediately on tap-up.
                // Rename (the old double-tap) is detected by hand inside
                // `handleSymbolTap`, so selection isn't held back waiting to
                // rule out a second tap.
                .onTapGesture {
                    handleSymbolTap()
                }
                // `.gesture(_, including: .none)` keeps the modifier
                // wired in the view tree (so SwiftUI preserves the
                // ComponentNodeView's state) while making the gesture
                // itself inert. Lock mode flips this so a stray finger
                // landing on the symbol during a pinch can't snag a
                // drag.
                .gesture(dragGesture, including: canvasLocked ? .none : .gesture)

            // Pin handles
            ForEach(component.pinKeys(snapshots: snapshots), id: \.self) { key in
                let offset = m.pinOffset(key)
                let ref = PinRef(componentId: component.id, pinKey: key)
                PinHandleView(
                    pinKey: pinDisplayLabel(key),
                    pinType: pinTypeLabel(key),
                    isFirstOfDrawingNet: isFirstPin(key),
                    onTap: { handlePinTap(key) },
                    onDragChanged: { pt in onPinDragChanged(ref, pt) },
                    onDragEnded: { pt in onPinDragEnded(ref, pt) }
                )
                .offset(x: offset.x, y: offset.y)
            }

            if isRenaming {
                renameField
                    .offset(y: m.size.height / 2 + 12)
            }
        }
        .offset(effectiveOffset)
        .onChange(of: dragInvalidation) { _, _ in
            // A second finger landed on the canvas — drop any in-flight
            // single-finger drag this node was tracking. SwiftUI's
            // DragGesture itself won't necessarily fire `.onEnded` in
            // response (the gesture isn't cancelled at the UIKit layer),
            // so we reset the visible offset here and mark cancelled so
            // a delayed `.onEnded` doesn't commit a stale position.
            if dragOffset != .zero || multiDrag?.participants.contains(component.id) == true {
                dragOffset = .zero
                dragCancelled = true
                liveDragShift = nil
            }
        }
    }

    private func handleSymbolTap() {
        if ModifierKeys.commandHeld {
            // Cmd-click toggles in/out of the multi-selection (never renames).
            lastTapTime = .distantPast
            var next = selection
            next.net = nil
            if next.components.contains(component.id) {
                next.components.remove(component.id)
            } else {
                next.components.insert(component.id)
            }
            selection = next
            return
        }
        // A second plain tap on the same component within the system
        // double-click window opens rename; the first tap already selected it.
        let now = Date()
        if now.timeIntervalSince(lastTapTime) < InputPlatform.doubleTapInterval {
            lastTapTime = .distantPast
            renameDraft = component.label
            isRenaming = true
            return
        }
        // First tap: select right away.
        lastTapTime = now
        selection = .component(component.id)
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        // `.global` matters: the symbol lives inside the ZStack we're offsetting,
        // so a `.local` translation would shrink to zero as the view moves under
        // the cursor and the component would fight the drag.
        // A 2 pt threshold suits a precise cursor; finger taps wobble more
        // than that, so raise it on iPad.
        let minDistance: Double = InputPlatform.isTouch ? 6 : 2
        return DragGesture(minimumDistance: minDistance, coordinateSpace: .global)
            .onChanged { value in
                // Skip ticks that arrive after a multi-touch cancel so a
                // trailing finger movement doesn't re-inflate the offset
                // we just zeroed.
                if dragCancelled { return }
                if multiDrag == nil && dragOffset == .zero {
                    // Decide on first tick: if this node is part of a
                    // multi-selection, drive the shared state so the rest
                    // of the group follows; otherwise fall back to local
                    // single-component drag.
                    if selection.contains(component: component.id), selection.components.count > 1 {
                        startMultiDrag(initialTranslation: unscaled(value.translation))
                        return
                    }
                }
                if multiDrag != nil {
                    multiDrag?.translation = unscaled(value.translation)
                } else {
                    dragOffset = unscaled(value.translation)
                    liveDragShift = SchematicDragShift(
                        participants: [component.id], translation: dragOffset
                    )
                }
            }
            .onEnded { value in
                liveDragShift = nil
                if dragCancelled {
                    dragCancelled = false
                    dragOffset = .zero
                    return
                }
                if let multi = multiDrag {
                    commitMultiDrag(multi, finalTranslation: unscaled(value.translation))
                    multiDrag = nil
                } else {
                    let current = document.circuit.schematic.position(for: component.id)
                        ?? Point(x: 200, y: 200)
                    let local = unscaled(value.translation)
                    let next = SchematicLayout.snapToGrid(Point(
                        x: current.x + local.width,
                        y: current.y + local.height
                    ))
                    document.circuit.schematic.setPosition(next, for: component.id)
                    dragOffset = .zero
                    selection = .component(component.id)
                }
            }
    }

    /// Converts a `.global`-coord drag translation (always in screen pixels)
    /// into schematic coord units by dividing by the canvas zoom factor.
    private func unscaled(_ size: CGSize) -> CGSize {
        let s = max(0.01, schematicZoom)
        return CGSize(width: size.width / s, height: size.height / s)
    }

    private func startMultiDrag(initialTranslation: CGSize) {
        var originals: [UUID: Point] = [:]
        for id in selection.components {
            if let p = document.circuit.schematic.position(for: id) {
                originals[id] = p
            }
        }
        multiDrag = SchematicMultiDrag(
            participants: selection.components,
            originals: originals,
            translation: initialTranslation
        )
    }

    private func commitMultiDrag(_ multi: SchematicMultiDrag, finalTranslation: CGSize) {
        for (id, original) in multi.originals {
            let next = SchematicLayout.snapToGrid(Point(
                x: original.x + finalTranslation.width,
                y: original.y + finalTranslation.height
            ))
            document.circuit.schematic.setPosition(next, for: id)
        }
    }

    // MARK: - Pin tap

    /// User-facing pin label and short type, shared with the net-endpoint
    /// tooltips via `SchematicPinDescriptor` so both read the same.
    private func pinDisplayLabel(_ key: String) -> String {
        SchematicPinDescriptor.name(component, key: key, snapshots: document.circuit.librarySnapshots)
    }

    private func pinTypeLabel(_ key: String) -> String? {
        SchematicPinDescriptor.type(component, key: key, snapshots: document.circuit.librarySnapshots)
    }

    private func isFirstPin(_ key: String) -> Bool {
        if case let .awaitingSecondPin(firstPin) = netDrawState {
            return firstPin.componentId == component.id && firstPin.pinKey == key
        }
        return false
    }

    private func handlePinTap(_ key: String) {
        let ref = PinRef(componentId: component.id, pinKey: key)
        switch netDrawState {
        case .idle:
            netDrawState = .awaitingSecondPin(firstPin: ref)
        case .awaitingSecondPin(let firstPin):
            defer { netDrawState = .idle }
            guard firstPin != ref else { return }    // same pin twice → cancel
            document.circuit.connectPins(firstPin, ref)
        }
    }

    // MARK: - Rename

    private var renameField: some View {
        let field = TextField("Label", text: $renameDraft, onCommit: commitRename)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .focused($renameFieldFocused)
            .onAppear { renameFieldFocused = true }
        #if canImport(AppKit)
        return field.onExitCommand { isRenaming = false }
        #else
        return field
        #endif
    }

    private func commitRename() {
        defer { isRenaming = false }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let i = document.circuit.logic.components.firstIndex(where: { $0.id == component.id }) {
            document.circuit.logic.components[i].label = trimmed
        }
    }
}
