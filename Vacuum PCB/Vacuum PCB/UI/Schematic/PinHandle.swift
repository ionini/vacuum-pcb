import SwiftUI

/// Small interactive circle drawn at each pin location. Click target for the
/// net-drawing interaction; visually highlights when hovered or when it's the
/// first pin of an in-progress net.
struct PinHandleView: View {
    let pinKey: String
    let isFirstOfDrawingNet: Bool
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Circle()
            .fill(fillColor)
            .overlay(Circle().stroke(strokeColor, lineWidth: 1.0))
            .frame(width: 10, height: 10)
            .contentShape(Rectangle().size(width: 22, height: 22))
            .onHover { hovered = $0 }
            .onTapGesture { onTap() }
            .help(pinKey)
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
