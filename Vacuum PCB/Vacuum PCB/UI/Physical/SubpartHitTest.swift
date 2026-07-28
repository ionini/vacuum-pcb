import Foundation

/// One sub-part instance whose body covers a canvas point, plus where it sits
/// in the nesting chain. Board A embeds B, B embeds C: a click on a feature
/// that belongs to C yields two hits — B at depth 0 and C at depth 1 — so a
/// menu can offer to open either file.
struct SubpartHit: Identifiable {
    /// The instance's `componentId` in its own parent's logic graph. Unique
    /// per level, which is all the menu needs; the same library opened at two
    /// places on the board has two distinct ids.
    let id: UUID
    /// 0 for a sub-part placed directly on the open board, 1 for a sub-part of
    /// that sub-part, and so on.
    let depth: Int
    /// Instance labels from the outermost sub-part down to this one — ["B1"],
    /// then ["B1", "C1"]. The open board itself isn't included.
    let path: [String]
    /// Library filename to open (`Component.partRef`).
    let partRef: String
    /// Filename without the `.vpcb` extension.
    let displayName: String

    var breadcrumb: String { path.joined(separator: " ▸ ") }
}

/// Point-in-sub-part hit testing that follows the nesting all the way down.
///
/// The canvas draws sub-parts fully expanded — `SubpartExpandedView` recurses
/// through every level — but the whole expansion is `allowsHitTesting(false)`,
/// so a click only ever resolves to the top-level placement. This walks the
/// same tree the renderer walks, letting the context menu name every level
/// under the cursor instead of just the outermost one.
///
/// Containment is tested against each library's `boardOutline`: the dotted
/// rectangle the canvas draws around the instance, which is what the user
/// reads as "that part's area". Rather than transforming every nested outline
/// up into board space, the query point is pushed *down* into each library's
/// local coordinates — the inverse of `SubpartExpandedView.transformWorld`.
enum SubpartHitTest {
    /// Depth-first, pre-order: each top-level sub-part covering `point`,
    /// immediately followed by its own nested hits. Overlapping siblings all
    /// appear (socket-mated assemblies stack every sub-part at one origin), so
    /// the caller gets one flat list to render in menu order.
    static func hits(at point: Point, in document: CircuitDocument) -> [SubpartHit] {
        var out: [SubpartHit] = []
        walk(
            point: point,
            document: document,
            snapshots: document.librarySnapshots,
            path: [],
            depth: 0,
            visiting: [],
            into: &out
        )
        return out
    }

    private static func walk(
        point: Point,
        document: CircuitDocument,
        snapshots: [String: CircuitDocument],
        path: [String],
        depth: Int,
        visiting: Set<String>,
        into out: inout [SubpartHit]
    ) {
        for placement in document.physical.placements {
            guard let component = document.logic.components
                    .first(where: { $0.id == placement.componentId }),
                  component.kind == .subpart,
                  let filename = component.partRef,
                  // Cycle guard, keyed by library filename to match the rule
                  // `SubpartExpandedView` and `CircuitDocument.flattened` use.
                  !visiting.contains(filename),
                  let part = component.resolvedPart(snapshots: snapshots)
            else { continue }
            let outline = part.document.physical.boardOutline
            let local = localPoint(point, in: placement, outline: outline)
            guard contains(outline, local) else { continue }
            let childPath = path + [component.label]
            out.append(SubpartHit(
                id: component.id,
                depth: depth,
                path: childPath,
                partRef: filename,
                displayName: part.displayName
            ))
            // Same snapshot swap the renderer performs at each level: a nested
            // reference resolves out of THIS library's `librarySnapshots`, not
            // the parent's — a parent only pins its direct dependencies.
            walk(
                point: local,
                document: part.document,
                snapshots: part.document.librarySnapshots,
                path: childPath,
                depth: depth + 1,
                visiting: visiting.union([filename]),
                into: &out
            )
        }
    }

    /// Inverse of `SubpartExpandedView.transformWorld`: parent mm → library
    /// mm. Instances are corner-anchored (the library outline's top-left
    /// corner lands on `placement.position`, and the pose rotates about that
    /// corner), so undoing the pose is a translate followed by a rotation by
    /// −`placement.rotation`.
    static func localPoint(_ parent: Point, in placement: Placement, outline: Rect) -> Point {
        let dx = parent.x - placement.position.x
        let dy = parent.y - placement.position.y
        let r = -placement.rotation.radians
        let cosR = cos(r), sinR = sin(r)
        return Point(
            x: outline.minX + dx * cosR - dy * sinR,
            y: outline.minY + dx * sinR + dy * cosR
        )
    }

    /// Inclusive on all four edges, with a hair of tolerance so a click right
    /// on the dotted outline — or a rotated instance whose inverse transform
    /// lands a rounding step outside — still counts as inside.
    private static func contains(_ rect: Rect, _ p: Point) -> Bool {
        let epsilon = 1e-6
        return p.x >= rect.minX - epsilon && p.x <= rect.maxX + epsilon
            && p.y >= rect.minY - epsilon && p.y <= rect.maxY + epsilon
    }
}
