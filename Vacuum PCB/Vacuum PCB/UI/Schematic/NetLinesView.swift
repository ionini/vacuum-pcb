import SwiftUI

/// Renders nets as one line per edge in a hybrid layout: nets that have a
/// natural endpoint (a port or a rail) get drawn as a star anchored on that
/// pin; nets that connect only components fall back to a minimum spanning
/// tree on pin positions. So a net like (Q2.b, R3.1, Q6.b) with no port
/// shows Q2—R3—Q6, with each pin connected to its nearest neighbour in the
/// tree, instead of every pin spoking from whichever happened to be first.
///
/// Selected nets stroke wider in the accent color. Connector matings draw
/// on top as chunky indigo bus-lines so they read as "these two
/// connectors snap together, all N pins in parallel" rather than getting
/// lost in the regular net mesh.
struct NetLinesView: View {
    let document: CircuitDocument
    let selection: SchematicSelection
    /// Net the cursor is currently over, highlighted brighter/wider than the
    /// resting state so the whole connection lights up on hover. Selection
    /// still wins when both apply.
    var hoveredNet: UUID? = nil

    var body: some View {
        Canvas { ctx, _ in
            // Resolve pin positions once for the whole net mesh rather than
            // rebuilding the map per net.
            let geometry = NetEdgeBuilder.pinGeometry(in: document)
            for net in document.logic.nets {
                let style = netStroke(for: net.id)
                for edge in NetEdgeBuilder.edges(for: net, in: document, geometry: geometry) {
                    ctx.stroke(
                        edge.roundedPath(),
                        with: .color(style.color),
                        style: StrokeStyle(
                            lineWidth: style.width,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
            for mating in document.logic.matings {
                guard let a = MatingEndpointGeometry.point(for: mating.a, in: document),
                      let b = MatingEndpointGeometry.point(for: mating.b, in: document)
                else { continue }
                let da = MatingEndpointGeometry.exit(for: mating.a, selfPoint: a, otherPoint: b, in: document)
                let db = MatingEndpointGeometry.exit(for: mating.b, selfPoint: b, otherPoint: a, in: document)
                ctx.stroke(
                    WireRouter.roundedPath(WireRouter.route(from: a, da, to: b, db), radius: 9),
                    with: .color(.indigo.opacity(0.75)),
                    style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// Resting / hovered / selected stroke for a net. Selection is the
    /// strongest signal (full accent, widest); hover is a lighter accent so it
    /// reads as "this is what you'd select"; everything else is the quiet
    /// secondary rat's-nest line.
    private func netStroke(for netId: UUID) -> (color: Color, width: CGFloat) {
        if selection.contains(net: netId) { return (.accentColor, 2.5) }
        if netId == hoveredNet { return (.accentColor.opacity(0.55), 2.0) }
        return (.secondary, 1.2)
    }
}

/// Maps a `ConnectorEndpoint` to its visible position on the schematic
/// canvas — the centre of the connector symbol for top-level endpoints,
/// or the centre of the socket tab on the subpart symbol for subpart
/// sockets. Used by `NetLinesView` to draw mating bus-lines and by the
/// inspector for "Mated to" labels.
enum MatingEndpointGeometry {
    static func point(for endpoint: ConnectorEndpoint, in document: CircuitDocument) -> CGPoint? {
        switch endpoint {
        case .topLevel(let id):
            guard let comp = document.logic.components.first(where: { $0.id == id }),
                  comp.kind == .connector,
                  let pos = document.schematic.position(for: id)
            else { return nil }
            _ = comp
            return CGPoint(x: pos.x, y: pos.y)
        case .subpartSocket(let subpartId, let connectorId):
            guard let subpart = document.logic.components.first(where: { $0.id == subpartId }),
                  subpart.kind == .subpart,
                  let pos = document.schematic.position(for: subpartId)
            else { return nil }
            let metrics = ComponentSymbolMetrics
                .metrics(for: subpart, snapshots: document.librarySnapshots)
                .rotated(by: document.schematic.rotation(for: subpartId))
            guard let layout = metrics.sockets.first(where: { $0.connectorId == connectorId })
            else { return nil }
            return CGPoint(x: pos.x + layout.centre.x, y: pos.y + layout.centre.y)
        }
    }

    /// Direction the mating bus-line should leave an endpoint. A subpart
    /// socket leaves perpendicular to the (rotated) edge it sits on; a
    /// top-level connector centre — which has no natural side — heads straight
    /// toward the other endpoint.
    static func exit(
        for endpoint: ConnectorEndpoint,
        selfPoint: CGPoint,
        otherPoint: CGPoint,
        in document: CircuitDocument
    ) -> ExitDir {
        if case .subpartSocket(let subpartId, let connectorId) = endpoint,
           let subpart = document.logic.components.first(where: { $0.id == subpartId }),
           subpart.kind == .subpart {
            let metrics = ComponentSymbolMetrics
                .metrics(for: subpart, snapshots: document.librarySnapshots)
                .rotated(by: document.schematic.rotation(for: subpartId))
            if let layout = metrics.sockets.first(where: { $0.connectorId == connectorId }) {
                return ExitDir(side: layout.side)
            }
        }
        return ExitDir.from(CGPoint(x: otherPoint.x - selfPoint.x, y: otherPoint.y - selfPoint.y))
    }
}
