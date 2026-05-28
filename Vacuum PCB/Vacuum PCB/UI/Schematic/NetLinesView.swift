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

    var body: some View {
        Canvas { ctx, _ in
            for net in document.logic.nets {
                let isSelected = selection.contains(net: net.id)
                for edge in NetEdgeBuilder.edges(for: net, in: document) {
                    var path = Path()
                    path.move(to: edge.a.point)
                    path.addLine(to: edge.b.point)
                    ctx.stroke(
                        path,
                        with: .color(isSelected ? .accentColor : .secondary),
                        lineWidth: isSelected ? 2.5 : 1.2
                    )
                }
            }
            for mating in document.logic.matings {
                guard let a = MatingEndpointGeometry.point(for: mating.a, in: document),
                      let b = MatingEndpointGeometry.point(for: mating.b, in: document)
                else { continue }
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                ctx.stroke(
                    path,
                    with: .color(.indigo.opacity(0.75)),
                    style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
                )
            }
        }
        .allowsHitTesting(false)
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
            let metrics = ComponentSymbolMetrics.metrics(for: subpart, snapshots: document.librarySnapshots)
            guard let layout = metrics.sockets.first(where: { $0.connectorId == connectorId })
            else { return nil }
            return CGPoint(x: pos.x + layout.centre.x, y: pos.y + layout.centre.y)
        }
    }
}
