import Foundation

/// Which plate a pin sits on, relative to the placement's primary layer.
/// - `.same`: same plate as the placement.
/// - `.opposite`: the other plate (used for transistor source/drain pins, which are
///   on the plate opposite the dimple).
enum RelativeLayer: Hashable {
    case same
    case opposite

    func resolved(against base: Layer) -> Layer {
        switch self {
        case .same: return base
        case .opposite: return base == .top ? .bottom : .top
        }
    }
}

/// One pin of a component footprint.
/// - `offset` is in millimeters relative to the component anchor at rotation r0.
/// - `relativeLayer` is the pin's plate relative to the placement's primary layer.
struct FootprintPin: Hashable {
    let key: String
    let offset: Point
    let relativeLayer: RelativeLayer
}

/// Static geometric description of a component kind.
/// All values are in millimeters at rotation r0; rotation/translation applied at render time.
struct Footprint {
    let kind: ComponentKind
    let pins: [FootprintPin]

    /// Axis-aligned bounding box of the exclusion zone (no foreign channels may cross),
    /// at rotation r0. Origin is relative to the component anchor.
    let exclusionRect: Rect

    /// Loose visual bounding box for placement UI and snapping. At rotation r0.
    let boundingRect: Rect

    func pin(_ key: String) -> FootprintPin? {
        pins.first(where: { $0.key == key })
    }
}

extension ComponentKind {
    /// Resolves the footprint of this kind. `size` is required only for `.resistor`.
    func footprint(resistorSize: ResistorSize? = nil) -> Footprint {
        switch self {
        case .transistor:
            let halfPitch = 1.5
            let dimpleRadius = 2.5
            let margin = 0.5
            let half = dimpleRadius + margin
            return Footprint(
                kind: .transistor,
                pins: [
                    FootprintPin(key: "gate", offset: .zero,                       relativeLayer: .same),
                    FootprintPin(key: "a",    offset: Point(x: -halfPitch, y: 0),  relativeLayer: .opposite),
                    FootprintPin(key: "b",    offset: Point(x:  halfPitch, y: 0),  relativeLayer: .opposite),
                ],
                exclusionRect: Rect(
                    origin: Point(x: -half, y: -half),
                    size: Size(width: 2 * half, height: 2 * half)
                ),
                boundingRect: Rect(
                    origin: Point(x: -half, y: -half),
                    size: Size(width: 2 * half, height: 2 * half)
                )
            )

        case .resistor:
            // Resistor footprint is the same physical size regardless of S/M/L.
            // The S/M/L choice picks how aggressively the serpentine zigzags
            // inside this bounding box, *not* how big the body is.
            let length = ManufacturingConstants.resistorFootprintLength
            let width = ManufacturingConstants.resistorFootprintWidth
            let halfLen = length / 2
            let halfWid = width / 2
            return Footprint(
                kind: .resistor,
                pins: [
                    FootprintPin(key: "1", offset: Point(x: -halfLen, y: 0), relativeLayer: .same),
                    FootprintPin(key: "2", offset: Point(x:  halfLen, y: 0), relativeLayer: .same),
                ],
                exclusionRect: Rect(
                    origin: Point(x: -halfLen, y: -halfWid),
                    size: Size(width: length, height: width)
                ),
                boundingRect: Rect(
                    origin: Point(x: -halfLen, y: -halfWid),
                    size: Size(width: length, height: width)
                )
            )

        case .vacuumSource, .atmVent, .port:
            // Edge-entry horizontal bore. Anchor sits at the inner (channel-side) end;
            // rotation chooses the outgoing edge (r0 = +X, r90 = +Y, r180 = -X, r270 = -Y).
            // Pin "p" lives on the placement's layer (which plate the bore is drilled into).
            let half = 1.5
            return Footprint(
                kind: self,
                pins: [
                    FootprintPin(key: "p", offset: .zero, relativeLayer: .same),
                ],
                exclusionRect: Rect(
                    origin: Point(x: -half, y: -half),
                    size: Size(width: 2 * half, height: 2 * half)
                ),
                boundingRect: Rect(
                    origin: Point(x: -half, y: -half),
                    size: Size(width: 2 * half, height: 2 * half)
                )
            )
        }
    }

    /// Convenience: list of legal pin keys for this component kind.
    var pinKeys: [String] {
        switch self {
        case .transistor:   return ["gate", "a", "b"]
        case .resistor:     return ["1", "2"]
        case .vacuumSource, .atmVent, .port: return ["p"]
        }
    }
}

extension Component {
    /// Resolves the footprint for this component, taking resistor size into account.
    var footprint: Footprint {
        kind.footprint(resistorSize: resistorSize)
    }
}

extension FootprintPin {
    /// Offset rotated by `rotation`; translation to world is left to the caller.
    func rotatedOffset(_ rotation: Rotation) -> Point {
        let r = rotation.radians
        let c = cos(r)
        let s = sin(r)
        return Point(x: offset.x * c - offset.y * s,
                     y: offset.x * s + offset.y * c)
    }
}

extension Placement {
    /// World-coordinate position of a pin on this placement.
    func worldPosition(of pin: FootprintPin) -> Point {
        let rotated = pin.rotatedOffset(rotation)
        return Point(x: position.x + rotated.x, y: position.y + rotated.y)
    }

    /// Resolved layer the pin actually sits on.
    func resolvedLayer(of pin: FootprintPin) -> Layer {
        pin.relativeLayer.resolved(against: layer)
    }
}
