import SwiftUI

/// One option in the click-and-hold disambiguation menu. The label tells the
/// user what they'd select; `apply` commits the choice to the canvas's
/// selection state. We use a closure rather than an enum so adding new hit
/// categories (pin handles, subpart internals) is a single call-site change.
struct DisambigCandidate: Identifiable {
    let id = UUID()
    let label: String
    let systemImage: String
    let color: Color
    /// Draws a divider above this row. Set on the first entry of a group that
    /// does something other than select (the sub-part "Open in Tab" block), so
    /// a menu that mixes "pick what's under the cursor" with "jump to another
    /// file" doesn't read as one undifferentiated list.
    var startsSection: Bool = false
    let apply: () -> Void
}

/// Transient state shown while the disambiguator popover is open. The
/// `screenPoint` is the long-press location captured at gesture fire — used
/// to anchor the popover so it pops out of the cursor, not the canvas centre.
struct DisambigState: Identifiable {
    let id = UUID()
    let screenPoint: CGPoint
    let candidates: [DisambigCandidate]
}

/// Compact popover content. Items render as buttons in a vertical stack;
/// hovering tints the row so it reads like a context menu. The container
/// sizes to its longest label so a single-line "Screw S2 (top)" doesn't
/// produce a wide chrome around a short word.
struct DisambigPopover: View {
    let candidates: [DisambigCandidate]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, item in
                // Leading dividers only between groups — a section marker on
                // the very first row would hang a rule off the top edge.
                if item.startsSection && index > 0 {
                    Divider().padding(.vertical, 3)
                }
                DisambigRow(item: item) {
                    item.apply()
                    dismiss()
                }
            }
        }
        .padding(4)
        .frame(minWidth: 180)
    }
}

private struct DisambigRow: View {
    let item: DisambigCandidate
    let onSelect: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: item.systemImage)
                    .foregroundStyle(item.color)
                    .frame(width: 16)
                Text(item.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hover ? Color.accentColor.opacity(0.18) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
