import Foundation

enum Examples {

    /// Hardcoded reference inverter used by iter 1.
    /// NMOS-style RTL inverter:
    ///   - Q1 transistor: gate driven by IN, source on the VENT (atmospheric) rail,
    ///     drain on OUT.
    ///   - R1 pull-up resistor: between OUT and the VAC (vacuum) rail.
    ///   - Inputs: IN (port). Outputs: OUT (port).
    ///   - Power: VAC (vacuum source), VENT (atmospheric vent).
    static func inverter() -> CircuitDocument {

        let qId    = uuid("00000000-0000-0000-0000-000000000001") // transistor
        let rId    = uuid("00000000-0000-0000-0000-000000000002") // resistor
        let vacId  = uuid("00000000-0000-0000-0000-000000000003") // vacuum source
        let ventId = uuid("00000000-0000-0000-0000-000000000004") // atm vent
        let inId   = uuid("00000000-0000-0000-0000-000000000005") // input port
        let outId  = uuid("00000000-0000-0000-0000-000000000006") // output port

        let netVacId  = uuid("00000000-0000-0000-0001-000000000001")
        let netVentId = uuid("00000000-0000-0000-0001-000000000002")
        let netOutId  = uuid("00000000-0000-0000-0001-000000000003")
        let netInId   = uuid("00000000-0000-0000-0001-000000000004")

        let logic = LogicGraph(
            components: [
                Component(id: qId,    kind: .transistor,    label: "Q1"),
                Component(id: rId,    kind: .resistor,      label: "R1", resistorSize: .medium),
                Component(id: vacId,  kind: .vacuumSource,  label: "VAC"),
                Component(id: ventId, kind: .atmVent,       label: "VENT"),
                Component(id: inId,   kind: .port,          label: "IN",  portDirection: .input),
                Component(id: outId,  kind: .port,          label: "OUT", portDirection: .output),
            ],
            nets: [
                // VAC rail: pull-up R1 ties OUT to vacuum.
                Net(id: netVacId, label: "VAC", pins: [
                    PinRef(componentId: vacId, pinKey: "p"),
                    PinRef(componentId: rId,   pinKey: "2"),
                ]),
                // VENT rail: source side of Q1 ties to atmosphere.
                Net(id: netVentId, label: "VENT", pins: [
                    PinRef(componentId: ventId, pinKey: "p"),
                    PinRef(componentId: qId,    pinKey: "a"),
                ]),
                // OUT node: drain of Q1, pull-up to VAC through R1, drives OUT port.
                Net(id: netOutId, label: "OUT", pins: [
                    PinRef(componentId: qId,   pinKey: "b"),
                    PinRef(componentId: rId,   pinKey: "1"),
                    PinRef(componentId: outId, pinKey: "p"),
                ]),
                // IN node: drives Q1 gate (which lives on the bottom plate).
                Net(id: netInId, label: "IN", pins: [
                    PinRef(componentId: inId, pinKey: "p"),
                    PinRef(componentId: qId,  pinKey: "gate"),
                ]),
            ]
        )

        let physical = PhysicalLayout(
            placements: [
                // Q1 dimple on the bottom plate; a/b source/drain on the top plate.
                Placement(componentId: qId,    position: Point(x: 20, y: 15), rotation: .r0,   layer: .bottom),
                // Resistor serpentine on the top plate.
                Placement(componentId: rId,    position: Point(x: 35, y: 15), rotation: .r0,   layer: .top),
                // Vacuum source: edge bore from +X edge into the top plate.
                Placement(componentId: vacId,  position: Point(x: 47, y: 15), rotation: .r0,   layer: .top),
                // Atmospheric vent: edge bore from -X edge into the top plate.
                Placement(componentId: ventId, position: Point(x: 3,  y: 15), rotation: .r180, layer: .top),
                // Input port: edge bore from -X edge into the bottom plate (matches gate layer).
                Placement(componentId: inId,   position: Point(x: 3,  y: 8),  rotation: .r180, layer: .bottom),
                // Output port: edge bore from +X edge into the top plate.
                Placement(componentId: outId,  position: Point(x: 47, y: 22), rotation: .r0,   layer: .top),
            ],
            routes: [
                Route(netId: netVacId, segments: [
                    Segment(waypoints: [
                        Waypoint(position: Point(x: 47, y: 15)),
                        Waypoint(position: Point(x: 40, y: 15)),
                    ], layer: .top),
                ]),
                Route(netId: netVentId, segments: [
                    Segment(waypoints: [
                        Waypoint(position: Point(x: 3,    y: 15)),
                        Waypoint(position: Point(x: 18.5, y: 15)),
                    ], layer: .top),
                ]),
                Route(netId: netOutId, segments: [
                    // Drain to R1
                    Segment(waypoints: [
                        Waypoint(position: Point(x: 21.5, y: 15)),
                        Waypoint(position: Point(x: 30,   y: 15)),
                    ], layer: .top),
                    // Junction at (30,15) to OUT port at (47,22), routed Manhattan.
                    Segment(waypoints: [
                        Waypoint(position: Point(x: 30, y: 15)),
                        Waypoint(position: Point(x: 30, y: 22)),
                        Waypoint(position: Point(x: 47, y: 22)),
                    ], layer: .top),
                ]),
                Route(netId: netInId, segments: [
                    Segment(waypoints: [
                        Waypoint(position: Point(x: 3,  y: 8)),
                        Waypoint(position: Point(x: 20, y: 8)),
                        Waypoint(position: Point(x: 20, y: 15)),
                    ], layer: .bottom),
                ]),
            ],
            boardOutline: Rect(
                origin: Point(x: 0, y: 0),
                size: Size(width: 50, height: 30)
            )
        )

        return CircuitDocument(
            manufacturing: .defaults,
            logic: logic,
            physical: physical
        )
    }
}

/// Parses a UUID from a literal string. Crashes at compile/run time if malformed —
/// these are baked-in constants in the example, not user input.
private func uuid(_ s: String) -> UUID {
    guard let u = UUID(uuidString: s) else {
        preconditionFailure("Invalid UUID literal: \(s)")
    }
    return u
}
