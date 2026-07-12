import SwiftUI

/// Floating control strip pinned to the bottom of the physical canvas while
/// a route is being laid out.
///
/// On macOS the mid-route power moves live on the keyboard: V drops a
/// cross-silicone via, 0…9 drop a same-plate via to that depth, ⌫ backs out
/// the last point, Esc cancels. iPad has none of those without an external
/// keyboard — and the keyboard path aims the via at the hover cursor, which
/// touch doesn't have either. This HUD is the touch-first equivalent: the
/// layer chips drop a via **at the route head** (the last committed point,
/// i.e. exactly where the user just tapped) and continue routing on the
/// chosen layer. It renders on macOS too, as a discoverable mirror of the
/// shortcuts; the keyboard path is unchanged.
struct RoutingHUD: View {
    /// Display label of the net being routed.
    let netLabel: String
    /// Layer the in-progress segment is being cut on.
    let currentLayer: Layer
    /// Every configured channel layer, in T0…Tn, B0…Bm order — same order
    /// as the toolbar picker, so the chip row's geometry stays put while
    /// the route hops layers.
    let layers: [Layer]
    /// False until the polyline has at least one point beyond the start
    /// pin — a via needs a segment of nonzero length to terminate, so the
    /// chips stay disabled until the first tap lands.
    let viaReady: Bool
    let canUndo: Bool
    /// Non-empty while the route is still just its via pickup point: the
    /// layers that existing via already connects. Their chips switch the
    /// working layer in place (the bore is already drilled — no new via),
    /// and the caption flips from "Via to" to "Continue on".
    var pickupLayers: Set<Layer> = []
    /// Sticky stand-in for holding ⌘ on macOS: segments run straight
    /// (diagonal) to the tap instead of inserting a Manhattan elbow.
    @Binding var straight: Bool
    let onVia: (Layer) -> Void
    let onUndo: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Context: which net, which layer — tinted like the route stroke.
            HStack(spacing: 5) {
                Circle()
                    .fill(LayerPalette.color(for: currentLayer))
                    .frame(width: 9, height: 9)
                Text("\(netLabel) · \(currentLayer.uiLabel)")
                    .font(.system(size: fontSize, weight: .semibold))
            }
            Divider().frame(height: dividerHeight)
            Text(pickupLayers.isEmpty ? "Via to" : "Continue on")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(layers, id: \.self) { layer in
                    chip(for: layer)
                }
            }
            Divider().frame(height: dividerHeight)
            straightToggle
            iconButton("arrow.uturn.backward",
                       help: "Remove the last point (⌫)",
                       disabled: !canUndo,
                       action: onUndo)
            iconButton("xmark",
                       help: "Cancel routing (Esc)",
                       tint: .red,
                       action: onCancel)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.12))
        )
        // Swallow taps that land between the controls so they can't fall
        // through to the canvas and extend the route underneath the bar.
        .onTapGesture {}
    }

    // MARK: - Layer chips

    private enum ChipRole {
        /// The layer the route is currently on — highlighted, not tappable.
        case current
        /// Tapping drops a via at the route head and continues here.
        case target
        /// Not a legal via destination right now.
        case blocked
    }

    private func role(for layer: Layer) -> ChipRole {
        if layer == currentLayer { return .current }
        // At a via pickup, the layers the tapped via already connects are
        // free switches — everything else stays blocked until a point is
        // tapped (a *new* via can't anchor to a zero-length segment).
        if pickupLayers.contains(layer) { return .target }
        guard viaReady else { return .blocked }
        if layer.plate == currentLayer.plate { return .target }
        // Crossing plates punches through the silicone sheet, which only
        // the opposite plate's face layer (depth 0) touches.
        return layer.depth == 0 ? .target : .blocked
    }

    @ViewBuilder private func chip(for layer: Layer) -> some View {
        let role = role(for: layer)
        let color = LayerPalette.color(for: layer)
        Button { onVia(layer) } label: {
            Text(layer.uiLabel)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(chipForeground(role: role, color: color))
                .frame(minWidth: controlSide, minHeight: controlSide)
                .padding(.horizontal, 3)
                .background(
                    Capsule().fill(chipFill(role: role, color: color))
                )
                .overlay(
                    Capsule().stroke(
                        role == .target ? color.opacity(0.8) : .clear,
                        lineWidth: 1
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(role != .target)
        .help(chipHelp(for: layer, role: role))
    }

    private func chipForeground(role: ChipRole, color: Color) -> Color {
        switch role {
        case .current: return .white
        case .target:  return color
        case .blocked: return .secondary.opacity(0.45)
        }
    }

    private func chipFill(role: ChipRole, color: Color) -> Color {
        switch role {
        case .current: return color
        case .target:  return color.opacity(0.12)
        case .blocked: return .clear
        }
    }

    private func chipHelp(for layer: Layer, role: ChipRole) -> String {
        switch role {
        case .current:
            return "Routing on \(layer.uiLabel)"
        case .target where pickupLayers.contains(layer):
            return "Continue from this via on \(layer.uiLabel) — it already connects there"
        case .target where layer.plate == currentLayer.plate:
            return "Drop a via at the last point and continue on \(layer.uiLabel) (key \(layer.depth))"
        case .target:
            return "Drop a via through the silicone at the last point and continue on \(layer.uiLabel) (V)"
        case .blocked where !viaReady:
            return "Tap a point first — the via lands on the route's last point"
        case .blocked:
            return "Cross-silicone vias can only land on the opposite plate's face layer"
        }
    }

    // MARK: - Trailing controls

    private var straightToggle: some View {
        Button { straight.toggle() } label: {
            Image(systemName: "line.diagonal")
                .font(.system(size: glyphSize, weight: .medium))
                .frame(width: controlSide, height: controlSide)
                .foregroundStyle(straight ? Color.white : Color.primary)
                .background(Capsule().fill(straight ? Color.accentColor : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(straight
              ? "Straight segments on — taps connect directly, no elbow"
              : "Straight segments off — taps route with a right-angle elbow (or hold ⌘ per click)")
    }

    private func iconButton(
        _ systemName: String, help: String,
        disabled: Bool = false, tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .medium))
                .frame(width: controlSide, height: controlSide)
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    // MARK: - Metrics

    // macOS keeps the bar dainty for a cursor; iPad bumps every control to
    // a finger-sized target (the bar is the primary routing surface there).
    private var fontSize: CGFloat { InputPlatform.isTouch ? 13 : 11 }
    private var glyphSize: CGFloat { InputPlatform.isTouch ? 15 : 12 }
    private var controlSide: CGFloat { InputPlatform.isTouch ? 34 : 24 }
    private var dividerHeight: CGFloat { InputPlatform.isTouch ? 24 : 18 }
}

/// Transient banner for routing failures ("pin is on a different net…").
/// `routingError` used to be set but never rendered anywhere, so a
/// dead-ended route gave no feedback at all — especially confusing on
/// touch, where there's no cursor change to hint that routing stopped.
/// The canvas auto-clears the binding a few seconds after mounting this.
struct RoutingErrorToast: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: InputPlatform.isTouch ? 13 : 12, weight: .medium))
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.yellow.opacity(0.45))
        )
        .frame(maxWidth: 440)
    }
}
