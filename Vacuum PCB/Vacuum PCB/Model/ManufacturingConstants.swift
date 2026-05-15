import Foundation

/// Physical dimensions baked into a `CircuitDocument`. Per-document (not global)
/// because a printed plate is bound to the parameters it was generated for.
struct ManufacturingConstants: Codable, Hashable {
    /// Thickness of each plate (top and bottom each have this thickness).
    var plateThickness: Double

    /// Diameter of both horizontal channels (running through the plate midline)
    /// and the vertical drop bores at transistor pins (source / drain / gate),
    /// which connect the channel midline to the silicone-facing surface.
    var channelDiameter: Double

    /// Diameter of edge port bores (typically slightly wider than channels so a
    /// blunt-tip needle press-fits with a small interference).
    var portBoreDiameter: Double

    /// Thickness of the silicone sheet sandwiched between the two plates.
    var siliconeThickness: Double

    /// Diameter of the transistor dimple — the cup the silicone deflects into.
    var dimpleDiameter: Double

    /// Depth the dimple is recessed into the silicone-facing surface of its plate.
    var dimpleDepth: Double

    /// Snap-grid pitch used by the physical editor (mm). Not consumed by the CAD
    /// pipeline; lives here so it travels with the document.
    var gridPitch: Double

    /// Minimum allowed center-to-center distance between parallel channels.
    /// Consumed by DRC (iter 4), not by the CAD pipeline.
    var minChannelSpacing: Double

    /// Bore diameter for the serpentine inside a resistor footprint. Smaller
    /// than the regular channel so the resistor actually restricts flow — the
    /// resistor's pins are where a 1.5 mm transport channel meets a 0.5 mm
    /// orifice. S/M/L pick how many times the orifice zigzags inside the
    /// (fixed) footprint, not how wide it is.
    var resistorChannelDiameter: Double

    /// Plate material between two adjacent channel layers inside the same
    /// plate (only relevant when `PhysicalLayout` has more than one layer on
    /// that plate). Centre-to-centre spacing between consecutive layers is
    /// `channelDiameter + interLayerWall`.
    var interLayerWall: Double

    static let defaults = ManufacturingConstants(
        plateThickness: 5.0,
        channelDiameter: 1.5,
        portBoreDiameter: 1.6,
        siliconeThickness: 0.5,
        dimpleDiameter: 5.0,
        dimpleDepth: 1.0,
        gridPitch: 1.0,
        minChannelSpacing: 1.5,
        resistorChannelDiameter: 0.5,
        interLayerWall: 0.6
    )

    // Codable hand-rolled so older .vpcb files (written before
    // resistorChannelDiameter or interLayerWall existed) still decode — they
    // get the default for any field they didn't write.
    private enum CodingKeys: String, CodingKey {
        case plateThickness, channelDiameter, portBoreDiameter, siliconeThickness
        case dimpleDiameter, dimpleDepth, gridPitch, minChannelSpacing
        case resistorChannelDiameter, interLayerWall
    }

    init(plateThickness: Double, channelDiameter: Double, portBoreDiameter: Double,
         siliconeThickness: Double, dimpleDiameter: Double, dimpleDepth: Double,
         gridPitch: Double, minChannelSpacing: Double, resistorChannelDiameter: Double,
         interLayerWall: Double) {
        self.plateThickness = plateThickness
        self.channelDiameter = channelDiameter
        self.portBoreDiameter = portBoreDiameter
        self.siliconeThickness = siliconeThickness
        self.dimpleDiameter = dimpleDiameter
        self.dimpleDepth = dimpleDepth
        self.gridPitch = gridPitch
        self.minChannelSpacing = minChannelSpacing
        self.resistorChannelDiameter = resistorChannelDiameter
        self.interLayerWall = interLayerWall
    }

    /// Outer length of the resistor footprint (pin-to-pin distance). Constant
    /// across S/M/L; only the serpentine inside changes.
    static let resistorFootprintLength: Double = 12.0
    /// Outer width of the resistor footprint. Needs enough vertical room for
    /// the squiggle's plateaus plus the 0.5 mm channel radius.
    static let resistorFootprintWidth: Double = 4.0

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plateThickness = try c.decode(Double.self, forKey: .plateThickness)
        channelDiameter = try c.decode(Double.self, forKey: .channelDiameter)
        portBoreDiameter = try c.decode(Double.self, forKey: .portBoreDiameter)
        siliconeThickness = try c.decode(Double.self, forKey: .siliconeThickness)
        dimpleDiameter = try c.decode(Double.self, forKey: .dimpleDiameter)
        dimpleDepth = try c.decode(Double.self, forKey: .dimpleDepth)
        gridPitch = try c.decode(Double.self, forKey: .gridPitch)
        minChannelSpacing = try c.decode(Double.self, forKey: .minChannelSpacing)
        resistorChannelDiameter = try c.decodeIfPresent(Double.self,
                                                       forKey: .resistorChannelDiameter) ?? 0.5
        interLayerWall = try c.decodeIfPresent(Double.self,
                                              forKey: .interLayerWall) ?? 0.6
    }

    /// Effective thickness of a plate with `layerCount` channel layers. The
    /// single-layer case (legacy) reduces to exactly `plateThickness` — depth
    /// 0 sits at the plate midline as before. Each additional layer extends
    /// the plate outward by `channelDiameter + interLayerWall`, preserving
    /// the depth-0 channel's position relative to the silicone face.
    func plateThickness(forLayerCount layerCount: Int) -> Double {
        plateThickness + Double(max(0, layerCount - 1)) * (channelDiameter + interLayerWall)
    }

    /// World-Z of a channel layer's midline. The silicone gap is centred on
    /// z = 0 with the top plate above (`topInnerZ = +siliconeThickness/2`)
    /// and the bottom plate below. Depth 0 sits at the silicone-facing half
    /// of the original plate slab (preserving today's geometry); each deeper
    /// layer steps outward by `channelDiameter + interLayerWall`.
    func midZ(for layer: Layer) -> Double {
        let innerZ = layer.plate == .top
            ? siliconeThickness / 2
            : -siliconeThickness / 2
        let baseOffset = plateThickness / 2 + Double(layer.depth) * (channelDiameter + interLayerWall)
        return layer.plate == .top ? innerZ + baseOffset : innerZ - baseOffset
    }
}
