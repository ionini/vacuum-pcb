import SwiftUI

/// Small interactive circle drawn at each pin location. Click target for the
/// net-drawing interaction; visually highlights when hovered or when it's the
/// first pin of an in-progress net. Hover also surfaces a floating chip with
/// the pin name and type — the dot alone is too small to disambiguate, and
/// the OS-native `.help()` tooltip has a long delay.
struct PinHandleView: View {
    let pinKey: String
    /// Short type descriptor, e.g. "Gate", "Source/Drain", "Input", "VAC".
    /// Optional — primitives that have a self-explanatory name can pass nil.
    let pinType: String?
    let isFirstOfDrawingNet: Bool
    let onTap: () -> Void
    /// Drag callbacks used to draw a net by dragging from this pin and
    /// releasing on another. Locations come back in the schematic-canvas
    /// coord space (same units pin positions are stored in) so the parent
    /// can hit-test directly. Defaults to no-op so passive call sites
    /// don't have to provide them.
    var onDragChanged: (CGPoint) -> Void = { _ in }
    var onDragEnded: (CGPoint) -> Void = { _ in }

    @State private var hovered = false
    /// On touch platforms the chip is surfaced by a tap (and self-dismisses
    /// after a beat) since `.onHover` never fires without a cursor.
    @State private var touchChipUntil: Date?
    /// When the canvas is locked into pan/zoom mode, the drag-to-route
    /// gesture is masked to `.none` so the canvas's pan gesture wins.
    @Environment(\.canvasLocked) private var canvasLocked: Bool

    init(
        pinKey: String,
        pinType: String? = nil,
        isFirstOfDrawingNet: Bool,
        onTap: @escaping () -> Void,
        onDragChanged: @escaping (CGPoint) -> Void = { _ in },
        onDragEnded: @escaping (CGPoint) -> Void = { _ in }
    ) {
        self.pinKey = pinKey
        self.pinType = pinType
        self.isFirstOfDrawingNet = isFirstOfDrawingNet
        self.onTap = onTap
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    var body: some View {
        // iPad fingers cover much more area than a cursor; a 22 pt hit zone
        // is right on the touch HIG floor. 26 pt gives a bit of slop without
        // bleeding onto neighbouring pins on tight footprints.
        let dot: CGFloat = InputPlatform.isTouch ? 12 : 10
        let hit: CGFloat = InputPlatform.isTouch ? 26 : 22
        return Circle()
            .fill(fillColor)
            .overlay(Circle().stroke(strokeColor, lineWidth: 1.0))
            .frame(width: dot, height: dot)
            .contentShape(Rectangle().size(width: hit, height: hit))
            .onHover { hovered = $0 }
            .onTapGesture {
                if InputPlatform.isTouch { flashTouchChip() }
                onTap()
            }
            // Drag-from-pin draws a net to wherever the user releases.
            // minimumDistance keeps a small wobble from turning a tap into
            // an accidental drag — short presses still fall through to
            // .onTapGesture. The coord space name is set on
            // SchematicCanvasView's scaled inner content so values arrive
            // pre-scaled, in the same schematic units pin positions live in.
            .gesture(
                DragGesture(minimumDistance: InputPlatform.isTouch ? 8 : 4,
                            coordinateSpace: .named("schematic-canvas"))
                    .onChanged { value in onDragChanged(value.location) }
                    .onEnded   { value in onDragEnded(value.location) },
                including: canvasLocked ? .none : .gesture
            )
            .overlay(alignment: .bottom) {
                if showChip {
                    hoverChip
                        .fixedSize()
                        // Sit above the dot so the cursor doesn't sit on the
                        // chip — that'd trigger SwiftUI's hover-end flicker
                        // as the cursor crossed the seam.
                        .offset(y: -16)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.08), value: hovered)
            .animation(.easeOut(duration: 0.12), value: touchChipUntil)
            // Raise the hovered pin above its sibling pins so the floating
            // chip draws on top of neighbouring dots instead of being covered
            // by whichever pin is later in the parent's ForEach.
            .zIndex(showChip ? 1 : 0)
    }

    private var showChip: Bool {
        if hovered { return true }
        if let until = touchChipUntil, until > .now { return true }
        return false
    }

    /// Pop the chip for ~1.4 s after a tap so the user can confirm which
    /// pin they actually hit before the routing state machine reacts.
    private func flashTouchChip() {
        let deadline = Date.now.addingTimeInterval(1.4)
        touchChipUntil = deadline
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if touchChipUntil == deadline { touchChipUntil = nil }
        }
    }

    private var hoverChip: some View {
        VStack(spacing: 0) {
            Text(pinKey)
                .font(.system(size: 10, weight: .semibold))
            if let pinType {
                Text(pinType)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.primary.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var fillColor: Color {
        if isFirstOfDrawingNet { return .accentColor }
        if hovered { return .accentColor.opacity(0.5) }
        return Color.primary.opacity(0.55)
    }

    private var strokeColor: Color {
        if isFirstOfDrawingNet { return .accentColor }
        return Color.primary.opacity(0.85)
    }
}
