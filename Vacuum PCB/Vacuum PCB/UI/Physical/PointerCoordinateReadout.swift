import SwiftUI

/// Live X/Y readout of the pointer's position in board millimetres, shown
/// in the bottom-left corner of the physical canvas (CAD status-bar
/// convention). Styled to match `ZoomToolbar`. Purely informational —
/// `allowsHitTesting(false)` at the call site keeps it out of the way of
/// canvas interaction.
///
/// Coordinates are in the same world frame as everything else in the
/// document (placement positions, route waypoints), so the readout doubles
/// as a way to eyeball where a part sits, not just where the cursor is.
struct PointerCoordinateReadout: View {
    /// Pointer position in board millimetres (world frame), already mapped
    /// through the canvas transform by the caller.
    let world: Point

    var body: some View {
        HStack(spacing: 8) {
            axis("X", world.x)
            axis("Y", world.y)
            Text("mm")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: InputPlatform.isTouch ? 12 : 11,
                      weight: .medium, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12))
        )
    }

    private func axis(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.secondary)
            // Fixed-width, trailing-aligned so the panel doesn't jitter as
            // the value (and its sign) changes under a moving cursor.
            Text(String(format: "%.2f", value))
                .foregroundStyle(.primary)
                .frame(minWidth: 48, alignment: .trailing)
        }
    }
}
