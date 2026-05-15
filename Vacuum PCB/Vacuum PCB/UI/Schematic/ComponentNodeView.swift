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

    @State private var dragOffset: CGSize = .zero
    @State private var isRenaming = false
    @State private var renameDraft: String = ""

    private var metrics: ComponentSymbolMetrics {
        ComponentSymbolMetrics.metrics(for: component.kind)
    }

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
        ZStack {
            ComponentSymbolView(component: component, isSelected: isSelected)
                .onTapGesture {
                    handleSymbolTap()
                }
                .onTapGesture(count: 2) {
                    renameDraft = component.label
                    isRenaming = true
                }
                .gesture(dragGesture)

            // Pin handles
            ForEach(component.kind.pinKeys, id: \.self) { key in
                let offset = metrics.pinOffset(key)
                PinHandleView(
                    pinKey: key,
                    isFirstOfDrawingNet: isFirstPin(key),
                    onTap: { handlePinTap(key) }
                )
                .offset(x: offset.x, y: offset.y)
            }

            if isRenaming {
                renameField
                    .offset(y: metrics.size.height / 2 + 12)
            }
        }
        .offset(effectiveOffset)
    }

    private func handleSymbolTap() {
        if NSEvent.modifierFlags.contains(.command) {
            // Cmd-click toggles in/out of the multi-selection.
            var next = selection
            next.net = nil
            if next.components.contains(component.id) {
                next.components.remove(component.id)
            } else {
                next.components.insert(component.id)
            }
            selection = next
        } else {
            selection = .component(component.id)
        }
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        // `.global` matters: the symbol lives inside the ZStack we're offsetting,
        // so a `.local` translation would shrink to zero as the view moves under
        // the cursor and the component would fight the drag.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if multiDrag == nil && dragOffset == .zero {
                    // Decide on first tick: if this node is part of a
                    // multi-selection, drive the shared state so the rest
                    // of the group follows; otherwise fall back to local
                    // single-component drag.
                    if selection.contains(component: component.id), selection.components.count > 1 {
                        startMultiDrag(initialTranslation: value.translation)
                        return
                    }
                }
                if multiDrag != nil {
                    multiDrag?.translation = value.translation
                } else {
                    dragOffset = value.translation
                }
            }
            .onEnded { value in
                if let multi = multiDrag {
                    commitMultiDrag(multi, finalTranslation: value.translation)
                    multiDrag = nil
                } else {
                    let current = document.circuit.schematic.position(for: component.id)
                        ?? Point(x: 200, y: 200)
                    let next = Point(
                        x: current.x + value.translation.width,
                        y: current.y + value.translation.height
                    )
                    document.circuit.schematic.setPosition(next, for: component.id)
                    dragOffset = .zero
                    selection = .component(component.id)
                }
            }
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
            let next = Point(
                x: original.x + finalTranslation.width,
                y: original.y + finalTranslation.height
            )
            document.circuit.schematic.setPosition(next, for: id)
        }
    }

    // MARK: - Pin tap

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
            connect(firstPin: firstPin, secondPin: ref)
        }
    }

    /// Adds `secondPin` to the same net as `firstPin`. Cases:
    /// - Neither pin is on any net → create a new net with both.
    /// - One pin already on a net → add the other to that net.
    /// - Both on different nets → merge the two nets (keep the first net's id).
    /// - Both on the same net → toggle: remove `secondPin` from the net
    ///   (and delete the net if it falls below 2 pins).
    private func connect(firstPin: PinRef, secondPin: PinRef) {
        var nets = document.circuit.logic.nets
        let firstIdx = nets.firstIndex { $0.pins.contains(firstPin) }
        let secondIdx = nets.firstIndex { $0.pins.contains(secondPin) }

        switch (firstIdx, secondIdx) {
        case (nil, nil):
            let label = document.circuit.logic.nextNetLabel()
            nets.append(Net(label: label, pins: [firstPin, secondPin]))
        case (let i?, nil):
            nets[i].pins.append(secondPin)
        case (nil, let j?):
            nets[j].pins.append(firstPin)
        case (let i?, let j?) where i == j:
            // Toggle off: remove the second pin from the shared net.
            nets[i].pins.removeAll { $0 == secondPin }
            if nets[i].pins.count < 2 {
                let killedNetId = nets[i].id
                nets.remove(at: i)
                document.circuit.physical.routes.removeAll { $0.netId == killedNetId }
            }
        case (let a?, let b?):
            // Merge the higher-index net into the lower-index one and drop the
            // higher. Removing the higher index leaves the lower untouched.
            let i = min(a, b), j = max(a, b)
            let merged = nets[j].pins
            nets[i].pins.append(contentsOf: merged.filter { !nets[i].pins.contains($0) })
            let killedNetId = nets[j].id
            nets.remove(at: j)
            document.circuit.physical.routes.removeAll { $0.netId == killedNetId }
        }
        document.circuit.logic.nets = nets
    }

    // MARK: - Rename

    private var renameField: some View {
        TextField("Label", text: $renameDraft, onCommit: commitRename)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .onExitCommand { isRenaming = false }
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
