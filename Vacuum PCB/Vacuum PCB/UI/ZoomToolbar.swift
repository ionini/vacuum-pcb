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

/// Floating zoom controls reused by the schematic and physical canvases.
/// Three buttons: zoom out, fit-to-view, zoom in, plus a percentage readout.
/// Each canvas owns its own zoom state; this view is purely action callbacks.
struct ZoomToolbar: View {
    /// Current zoom factor, 1.0 = neutral / fit-to-view scale. The readout
    /// formats it as a percentage so the user has feedback on how far they've
    /// strayed from the fitted baseline.
    let zoomPercent: Double
    let onZoomOut: () -> Void
    let onFit: () -> Void
    let onZoomIn: () -> Void

    var body: some View {
        HStack(spacing: 4) {
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
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
