import SwiftUI

/// Inspector section that folds its content behind a tappable header, so the
/// dynamic blocks (physical volumes, supply budget, per-transistor readouts)
/// don't dominate the sidebar on busy boards. Expansion is remembered per
/// section key across tab switches and launches; every section starts
/// collapsed on first run.
///
/// The whole header row is the hit target (not just the chevron, which is
/// fiddly on iPad), and the content builder isn't evaluated while collapsed —
/// so a collapsed section full of live 20 Hz readout rows costs nothing.
struct CollapsibleSection<Content: View>: View {
    let title: String
    var titleFont: Font
    @AppStorage private var expanded: Bool
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        storageKey: String,
        titleFont: Font = .subheadline.bold(),
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.titleFont = titleFont
        self.content = content
        _expanded = AppStorage(wrappedValue: false, storageKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(title).font(titleFont)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                content()
            }
        }
    }
}
