import SwiftUI

/// Schematic-canvas zoom factor exposed to children so that `.global`-coord
/// drag gestures (component move, multi-drag) can divide their pixel
/// translation by zoom to land in the schematic's unscaled coord space.
/// Default 1.0 means "no scaling applied" — safe for any view that's not
/// inside a scaled subtree.
private struct SchematicZoomKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var schematicZoom: Double {
        get { self[SchematicZoomKey.self] }
        set { self[SchematicZoomKey.self] = newValue }
    }
}

/// `true` while the canvas is in pan/zoom-only mode (the lock button in
/// `ZoomToolbar` is on). Drag-attaching subviews — ComponentNodeView,
/// PinHandleView, PhysicalPinHandle — read this and mask their
/// DragGestures to `.none`, so even mid-pinch a wandering single finger
/// can't snag a component or pin. The canvas itself still owns a
/// high-priority pan gesture for the actual pan motion.
private struct CanvasLockedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var canvasLocked: Bool {
        get { self[CanvasLockedKey.self] }
        set { self[CanvasLockedKey.self] = newValue }
    }
}

/// Floating zoom controls reused by the schematic and physical canvases.
/// Lock button + zoom out / fit-to-view / zoom in / percentage readout.
/// Each canvas owns its own zoom + lock state; this view is purely
/// action callbacks.
struct ZoomToolbar: View {
    /// Current zoom factor, 1.0 = neutral / fit-to-view scale. The readout
    /// formats it as a percentage so the user has feedback on how far they've
    /// strayed from the fitted baseline.
    let zoomPercent: Double
    let onZoomOut: () -> Void
    let onFit: () -> Void
    let onZoomIn: () -> Void
    /// Whether the canvas is in navigate-only ("locked") mode — see
    /// `canvasLocked` environment key. Drives the lock button's glyph
    /// and accent colour so the state is glanceable.
    var isLocked: Bool = false
    /// nil hides the lock button (used by call sites that don't need to
    /// expose the mode). When provided, taps toggle the parent's state.
    var onToggleLock: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let onToggleLock {
                lockButton(action: onToggleLock)
                // Vertical hairline keeps the lock visually distinct from
                // the zoom cluster — it changes mode rather than view.
                Divider().frame(height: 18)
            }
            button(systemName: "minus.magnifyingglass", help: "Zoom out (⌘−)", action: onZoomOut)
            button(systemName: "rectangle.dashed", help: "Fit to view (⌘0)", action: onFit)
            button(systemName: "plus.magnifyingglass", help: "Zoom in (⌘=)", action: onZoomIn)
            Text(percentLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12))
        )
    }

    private var percentLabel: String {
        "\(Int((zoomPercent * 100).rounded()))%"
    }

    private func button(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        // 22 pt is fine for a mouse cursor but well below the iOS HIG touch
        // target. Bump on touch so iPad fingers can land each control without
        // hitting its neighbour.
        let side: CGFloat = InputPlatform.isTouch ? 32 : 22
        let glyph: CGFloat = InputPlatform.isTouch ? 16 : 12
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyph, weight: .medium))
                .frame(width: side, height: side)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Lock button styled to mirror the zoom buttons but tinted with the
    /// accent colour when active so the lock state reads from across the
    /// canvas.
    private func lockButton(action: @escaping () -> Void) -> some View {
        let side: CGFloat = InputPlatform.isTouch ? 32 : 22
        let glyph: CGFloat = InputPlatform.isTouch ? 16 : 12
        let help = isLocked
            ? "Pan/zoom only — tap to re-enable editing"
            : "Lock for pan/zoom — disable component dragging"
        return Button(action: action) {
            Image(systemName: isLocked ? "lock.fill" : "lock.open")
                .font(.system(size: glyph, weight: .medium))
                .frame(width: side, height: side)
                .foregroundStyle(isLocked ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
