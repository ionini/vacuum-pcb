import Foundation

/// Human-readable descriptor for one entry of `ManufacturingConstants`.
///
/// Drives the copy/paste confirmation table (label, group, formatted value)
/// and the selective merge behind it: each field knows how to read its own
/// value and how to copy just itself from one constants struct into another.
///
/// `all` must list every stored property. `ManufacturingClipboardTests`
/// cross-checks the ids against the encoded JSON keys, so a newly added
/// constant fails the test rather than silently becoming un-pasteable.
struct ManufacturingParameterField: Identifiable {
    enum Value: Equatable {
        case number(Double, unit: String)
        case flag(Bool)

        var display: String {
            switch self {
            case .number(let v, let unit):
                let text = Self.trimmed(v)
                return unit.isEmpty ? text : "\(text) \(unit)"
            case .flag(let on):
                return on ? "On" : "Off"
            }
        }

        /// Fixed 3-decimal formatting with the trailing zeros shaved off, so
        /// 1.36 reads "1.36" and 3.0 reads "3" — matching how the inspector's
        /// `mmFormatter` prints the same numbers.
        private static func trimmed(_ v: Double) -> String {
            var s = String(format: "%.3f", v)
            if s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            return s
        }
    }

    /// Matches the property (and `CodingKey`) name. Used as the selection id
    /// in the paste sheet and as the JSON-key cross-check in tests.
    let id: String
    /// Inspector section this constant is edited under, so the confirmation
    /// table reads in the same order as `ManufacturingSettingsView`.
    let group: String
    let label: String
    let read: (ManufacturingConstants) -> Value
    /// Copies *only* this field from `source` into `target`.
    let copy: (ManufacturingConstants, inout ManufacturingConstants) -> Void

    private init(
        id: String, group: String, label: String,
        read: @escaping (ManufacturingConstants) -> Value,
        copy: @escaping (ManufacturingConstants, inout ManufacturingConstants) -> Void
    ) {
        self.id = id
        self.group = group
        self.label = label
        self.read = read
        self.copy = copy
    }

    private static func number(
        _ id: String, _ group: String, _ label: String,
        _ keyPath: WritableKeyPath<ManufacturingConstants, Double>,
        unit: String = "mm"
    ) -> ManufacturingParameterField {
        ManufacturingParameterField(
            id: id, group: group, label: label,
            read: { .number($0[keyPath: keyPath], unit: unit) },
            copy: { source, target in target[keyPath: keyPath] = source[keyPath: keyPath] })
    }

    private static func flag(
        _ id: String, _ group: String, _ label: String,
        _ keyPath: WritableKeyPath<ManufacturingConstants, Bool>
    ) -> ManufacturingParameterField {
        ManufacturingParameterField(
            id: id, group: group, label: label,
            read: { .flag($0[keyPath: keyPath]) },
            copy: { source, target in target[keyPath: keyPath] = source[keyPath: keyPath] })
    }

    static let all: [ManufacturingParameterField] = [
        .number("plateThickness", "Plates", "Plate thickness (single-layer)",
                \.plateThickness),
        .number("siliconeThickness", "Plates", "Silicone thickness", \.siliconeThickness),
        .number("interLayerWall", "Plates", "Inter-layer wall", \.interLayerWall),
        .number("plateCornerFillet", "Plates", "Corner fillet radius", \.plateCornerFillet),

        .number("channelDiameter", "Channels", "Channel diameter", \.channelDiameter),
        .number("resistorChannelDiameter", "Channels", "Resistor bore diameter",
                \.resistorChannelDiameter),
        .number("portBoreDiameter", "Channels", "Port bore diameter", \.portBoreDiameter),
        .number("portBoreTaperDegrees", "Channels", "Port bore taper",
                \.portBoreTaperDegrees, unit: "°"),
        .number("minChannelSpacing", "Channels", "Min channel spacing (routing)",
                \.minChannelSpacing),
        .number("minWallThickness", "Channels", "Min wall thickness (DRC)",
                \.minWallThickness),
        .flag("flatBottomChannels", "Channels", "Flat-bottom channels", \.flatBottomChannels),
        .number("testPointLabelSize", "Channels", "Test point label size",
                \.testPointLabelSize),

        .number("modifierMarginXY", "Print envelope", "Envelope padding XY (walls)",
                \.modifierMarginXY),
        .number("modifierMarginZ", "Print envelope", "Envelope padding Z (roof/floor)",
                \.modifierMarginZ),

        .number("dimpleDiameter", "Transistor gate", "Dome diameter", \.dimpleDiameter),
        .number("dimpleSphereOffset", "Transistor gate", "Dome sphere offset",
                \.dimpleSphereOffset),
        // Retained for codable compatibility; the dome geometry ignores it.
        .number("dimpleDepth", "Transistor gate", "Dimple depth (legacy)", \.dimpleDepth),

        .number("ledDimpleDiameter", "LED indicator", "Dimple diameter",
                \.ledDimpleDiameter),
        .number("ledDimpleDepth", "LED indicator", "Dimple depth", \.ledDimpleDepth),

        .number("padsDiameter", "Transistor source/drain pads", "Pads diameter",
                \.padsDiameter),
        .number("padsSeparation", "Transistor source/drain pads", "Pads separation",
                \.padsSeparation),
        .number("padsOffset", "Transistor source/drain pads", "Tube offset (centre)",
                \.padsOffset),
        .number("padsFilletRadius", "Transistor source/drain pads", "Edge fillet radius",
                \.padsFilletRadius),

        .number("screwHeadDepth", "Screws", "Head depth", \.screwHeadDepth),
        .number("screwNutDepth", "Screws", "Nut depth", \.screwNutDepth),
        .number("screwProtrusion", "Screws", "Head/nut protrusion", \.screwProtrusion),
        .number("screwDomeBaseDiameter", "Screws", "Volcano base diameter",
                \.screwDomeBaseDiameter),

        .number("stencilThickness", "Stencil", "Thickness", \.stencilThickness),
        .number("stencilViaPadding", "Stencil", "Via hole padding", \.stencilViaPadding),

        .number("castingMargin", "Mold", "Casting margin", \.castingMargin),
        .number("moldWallThickness", "Mold", "Wall thickness", \.moldWallThickness),

        .number("gridPitch", "Editor", "Grid pitch", \.gridPitch),
    ]

    /// `all` bucketed by `group`, in first-appearance order.
    static var grouped: [(group: String, fields: [ManufacturingParameterField])] {
        var order: [String] = []
        var buckets: [String: [ManufacturingParameterField]] = [:]
        for field in all {
            if buckets[field.group] == nil { order.append(field.group) }
            buckets[field.group, default: []].append(field)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

extension ManufacturingConstants {
    /// Which fields hold a different value in `other` than in `self`.
    func differingFields(from other: ManufacturingConstants) -> [ManufacturingParameterField] {
        ManufacturingParameterField.all.filter { $0.read(self) != $0.read(other) }
    }

    /// Selective paste: starts from `self` and copies over only the listed
    /// fields of `incoming`.
    ///
    /// Copy-and-mutate, like `ManufacturingActions.sanitized` — an unlisted
    /// (or newly added, not-yet-described) field passes through untouched
    /// instead of being reset to some memberwise default.
    func merging(_ incoming: ManufacturingConstants,
                 fields: Set<String>) -> ManufacturingConstants {
        var result = self
        for field in ManufacturingParameterField.all where fields.contains(field.id) {
            field.copy(incoming, &result)
        }
        return result
    }
}
