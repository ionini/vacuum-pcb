import Foundation

enum ComponentKind: String, Codable, CaseIterable {
    case transistor
    case resistor
    case vacuumSource
    case atmVent
    case port
    /// Instance of a reusable circuit defined in another `.vpcb` file in the
    /// parts library. The instance reads its pin layout and internal geometry
    /// from `partRef` on each open — by-reference, not embedded.
    case subpart
    /// Mechanical fastener punched through both plates: countersink head
    /// cavity on the top, clearance bore through to the bottom, hex-nut
    /// pocket on the underside. No pins; doesn't participate in the
    /// netlist. Placed and dragged on the physical canvas only.
    case screw
    /// Visual indicator. Same dimple-on-the-placement-layer construction
    /// as a transistor's gate (without source/drain pads), plus a
    /// cylindrical viewing hole through the opposite plate so the
    /// silicone deflection is visible from outside. One fluid pin; when
    /// the net is at vacuum the silicone gets sucked into the dimple
    /// (LED "on"); at atmosphere it sits flat (LED "off").
    case led
    /// Multi-pin edge interface for mating two physically separate plate
    /// stacks (each plate stack is its own `.vpcb` design). Adds a
    /// rectangular protrusion to the plate outline at the chosen edge,
    /// carrying N exposed tubes flanked by two end-cap screws. Mating to
    /// the matching half is the user's responsibility outside the app:
    /// design both halves as separate `.vpcb` files with opposite roles
    /// and matching pin counts.
    case connector
}

/// Which side of the connector pair this instance is. Mating is asymmetric:
/// the silicone is only carried by one half so the gasket isn't doubled at
/// the joint.
enum ConnectorRole: String, Codable, CaseIterable {
    /// Bottom plate **and** silicone extend out as a protrusion. Tubes rise
    /// from the bottom plate through the silicone, exposed at the top of
    /// the silicone (no top plate above the protrusion area). This half
    /// carries the gasket; mates against a `.topExtend` half from another
    /// `.vpcb`.
    case bottomExtend
    /// Top plate extends out as a protrusion. Tubes drop from the top plate
    /// to its underside, exposed there (no bottom plate or silicone below
    /// the protrusion area). Mates against a `.bottomExtend` half.
    case topExtend
}

/// Electrical behaviour of a connector's pins in simulation, *independent of*
/// the physical mating role (`ConnectorRole`, which only decides which plate
/// extends). Lets a connector be used as a bus terminal regardless of which
/// half carries the silicone.
///
/// - `.input`: each pin is a user-driven source (the old `.bottomExtend`
///   default) — it clamps its net to the chosen rail.
/// - `.output`: each pin is a read-only probe (the old `.topExtend` default).
/// - `.bidirectional`: each pin is a **bus** terminal — always a probe, plus
///   an *optional, finite-conductance* drive the user can assert during
///   standalone simulation. Because the drive is soft (see
///   `SimulationParameters.busDriveConductance`) and defaults to floating, an
///   on-board tri-state driver can still win the net, so the pin behaves like
///   a real shared wire rather than a hard source. Once the connector is
///   mated the pin is dropped entirely and its net merges with the peer's, so
///   the signal mode only matters for the un-mated / standalone case.
enum ConnectorSignal: String, Codable, CaseIterable {
    case input
    case output
    case bidirectional
}

enum ResistorSize: String, Codable, CaseIterable {
    case small = "S"
    case medium = "M"
    case large = "L"
    case extraLarge = "XL"
}

enum PortDirection: String, Codable, CaseIterable {
    case input
    case output
}

struct Component: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: ComponentKind
    var label: String
    var resistorSize: ResistorSize?
    var portDirection: PortDirection?
    /// Filename (relative to the user's parts folder) of the library .vpcb this
    /// instance references. Only meaningful for `.subpart`. Filename-only is
    /// deliberate: rename = relink.
    var partRef: String?
    /// Content hash (hex SHA-256) of the library document this instance was
    /// pinned to. The matching snapshot lives in `CircuitDocument.librarySnapshots`
    /// — flatten/render reads the snapshot, never the live library, so edits to
    /// the user's parts folder don't silently cascade into saved designs. Nil
    /// only for sub-parts whose library file was missing at migration time.
    var partRefHash: String?
    /// Pin count for `.connector` instances. Drives the footprint pin list
    /// and the physical protrusion's slot count. Nil for non-connector kinds.
    var connectorPinCount: Int?
    /// Number of clamp screws for `.connector` instances. Nil means the
    /// legacy "two end caps" layout — so connectors saved before this axis
    /// existed keep their exact geometry. Read via `?? 2`, never directly.
    /// Three or more splits the pins into `count - 1` near-even groups with a
    /// screw between each (see `ComponentKind.connectorScrewLocalYs`). A
    /// different screw count makes two halves mechanically incompatible (the
    /// bolt pattern won't line up) — mating them is allowed but flagged.
    var connectorScrewCount: Int?
    /// Role for `.connector` instances. See `ConnectorRole`. Nil for
    /// non-connector kinds.
    var connectorRole: ConnectorRole?
    /// Electrical signal mode for `.connector` instances. See
    /// `ConnectorSignal`. Nil means "derive from role" so connectors saved
    /// before the bus axis existed keep their old behaviour — read via
    /// `resolvedConnectorSignal`, never directly.
    var connectorSignal: ConnectorSignal?
    /// User-given names for a `.connector`'s pins, indexed positionally:
    /// element `i` names pin key `"\(i + 1)"`. A blank entry (or an index past
    /// the end / a nil array) falls back to the bare pin number — read via
    /// `connectorPinName(_:)`, never directly. The names are cosmetic: pins
    /// still mate and route by their numeric key, so renaming a pin never
    /// changes connectivity. Nil for non-connector kinds and for connectors
    /// the user hasn't named (keeps such docs byte-stable on save).
    var connectorPinNames: [String]?

    init(
        id: UUID = UUID(),
        kind: ComponentKind,
        label: String,
        resistorSize: ResistorSize? = nil,
        portDirection: PortDirection? = nil,
        partRef: String? = nil,
        partRefHash: String? = nil,
        connectorPinCount: Int? = nil,
        connectorScrewCount: Int? = nil,
        connectorRole: ConnectorRole? = nil,
        connectorSignal: ConnectorSignal? = nil,
        connectorPinNames: [String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.resistorSize = resistorSize
        self.portDirection = portDirection
        self.partRef = partRef
        self.partRefHash = partRefHash
        self.connectorPinCount = connectorPinCount
        self.connectorScrewCount = connectorScrewCount
        self.connectorRole = connectorRole
        self.connectorSignal = connectorSignal
        self.connectorPinNames = connectorPinNames
    }
}

extension Component {
    /// Resolved electrical signal mode for a connector pin. Falls back to the
    /// role-derived default for connectors saved before the signal axis
    /// existed: `.bottomExtend` drove its pins (`.input`), `.topExtend`
    /// probed them (`.output`). Meaningless for non-connector kinds; callers
    /// only consult it on `.connector` components.
    var resolvedConnectorSignal: ConnectorSignal {
        if let connectorSignal { return connectorSignal }
        switch connectorRole ?? .bottomExtend {
        case .bottomExtend: return .input
        case .topExtend:    return .output
        }
    }

    /// Display name for one connector pin, identified by its numeric key
    /// ("1"…"N"). Returns the user-given name when set and non-blank,
    /// otherwise the bare key. This is the single source of truth every
    /// surface (schematic, physical, simulator, imported-socket tooltip)
    /// routes through, so a pin reads the same everywhere. Non-connector
    /// kinds or unparseable keys return the key unchanged.
    func connectorPinName(_ key: String) -> String {
        guard kind == .connector,
              let names = connectorPinNames,
              let index = Int(key), index >= 1, index <= names.count
        else { return key }
        let name = names[index - 1]
        return name.isEmpty ? key : name
    }
}

struct PinRef: Codable, Hashable {
    var componentId: UUID
    var pinKey: String
}

struct Net: Codable, Identifiable, Hashable {
    var id: UUID
    var label: String
    var pins: [PinRef]

    init(id: UUID = UUID(), label: String, pins: [PinRef]) {
        self.id = id
        self.label = label
        self.pins = pins
    }
}

/// Identifies one half of a `Mating`. Top-level connectors live directly in
/// the parent document's logic graph and are addressed by their component
/// id. Subpart sockets live inside a referenced library snapshot — the
/// parent only sees them through a specific subpart placement, so we
/// address them via the subpart instance's component id (the placement
/// holder) plus the connector's component id inside that subpart's library
/// snapshot.
enum ConnectorEndpoint: Hashable {
    case topLevel(componentId: UUID)
    case subpartSocket(subpartId: UUID, connectorId: UUID)
}

extension ConnectorEndpoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, componentId, subpartId, connectorId
    }
    private enum Kind: String, Codable {
        case topLevel, subpartSocket
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .topLevel:
            self = .topLevel(componentId: try c.decode(UUID.self, forKey: .componentId))
        case .subpartSocket:
            self = .subpartSocket(
                subpartId: try c.decode(UUID.self, forKey: .subpartId),
                connectorId: try c.decode(UUID.self, forKey: .connectorId)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .topLevel(let id):
            try c.encode(Kind.topLevel, forKey: .kind)
            try c.encode(id, forKey: .componentId)
        case .subpartSocket(let sid, let cid):
            try c.encode(Kind.subpartSocket, forKey: .kind)
            try c.encode(sid, forKey: .subpartId)
            try c.encode(cid, forKey: .connectorId)
        }
    }
}

/// A pairing of two connector instances that mate face-to-face. Two boards
/// designed with compatible halves (opposite roles, matching pin count)
/// are joined by a `Mating` in the parent assembly document; the flatten
/// step expands each mating into N pin-pair net merges so the simulator
/// and DRC see the joined network.
struct Mating: Codable, Identifiable, Hashable {
    var id: UUID
    var a: ConnectorEndpoint
    var b: ConnectorEndpoint

    init(id: UUID = UUID(), a: ConnectorEndpoint, b: ConnectorEndpoint) {
        self.id = id
        self.a = a
        self.b = b
    }
}

struct LogicGraph: Hashable {
    var components: [Component]
    var nets: [Net]
    /// Connector mating relations. Empty for non-assembly documents.
    /// A document is in assembly mode iff its logic graph (or any of its
    /// subpart snapshots) contains a connector that participates in a
    /// mating, derived via `CircuitDocument.isAssembly`.
    var matings: [Mating]

    init(components: [Component] = [], nets: [Net] = [], matings: [Mating] = []) {
        self.components = components
        self.nets = nets
        self.matings = matings
    }
}

extension LogicGraph: Codable {
    private enum CodingKeys: String, CodingKey {
        case components, nets, matings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.components = try c.decode([Component].self, forKey: .components)
        self.nets = try c.decode([Net].self, forKey: .nets)
        // v4 and earlier files don't carry matings; default to empty so
        // pre-assembly docs round-trip unchanged.
        self.matings = try c.decodeIfPresent([Mating].self, forKey: .matings) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(components, forKey: .components)
        try c.encode(nets, forKey: .nets)
        // Only emit the matings key when non-empty so pre-assembly docs
        // stay byte-identical after a no-op load/save cycle.
        if !matings.isEmpty {
            try c.encode(matings, forKey: .matings)
        }
    }
}

extension LogicGraph {
    /// Picks the next unused label for a new component of `kind`.
    ///
    /// Transistors / resistors / ports always carry a numeric suffix (Q1, R1, IN1, OUT1).
    /// Rails (VAC, VENT) prefer the bare prefix when available, falling back to a
    /// numbered form when there's already one on the canvas. Whitespace-significant
    /// matches against existing labels so user-renamed components don't collide.
    func nextLabel(for kind: ComponentKind, portDirection: PortDirection? = nil) -> String {
        let used = Set(components.map(\.label))
        let prefix: String
        let allowUnnumbered: Bool
        switch kind {
        case .transistor:    prefix = "Q";    allowUnnumbered = false
        case .resistor:      prefix = "R";    allowUnnumbered = false
        case .vacuumSource:  prefix = "VAC";  allowUnnumbered = true
        case .atmVent:       prefix = "VENT"; allowUnnumbered = true
        case .port:
            switch portDirection {
            case .input:  prefix = "IN";  allowUnnumbered = false
            case .output: prefix = "OUT"; allowUnnumbered = false
            case nil:     prefix = "P";   allowUnnumbered = false
            }
        case .subpart:
            prefix = "U"; allowUnnumbered = false
        case .screw:
            prefix = "S"; allowUnnumbered = false
        case .led:
            prefix = "D"; allowUnnumbered = false
        case .connector:
            prefix = "J"; allowUnnumbered = false
        }
        if allowUnnumbered, !used.contains(prefix) {
            return prefix
        }
        var n = 1
        while used.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    /// Picks the next unused net label (n1, n2, ...).
    func nextNetLabel() -> String {
        let used = Set(nets.map(\.label))
        var n = 1
        while used.contains("n\(n)") { n += 1 }
        return "n\(n)"
    }
}
