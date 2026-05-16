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

    /// Diameter of edge port bores at the route end (the inner / narrowest
    /// end). The bore tapers outward at `portBoreTaperDegrees` so the wide
    /// end sits flush with the board edge — slip-fits a tapered needle tip
    /// and lets the diameter relax over the print's perimeter.
    var portBoreDiameter: Double

    /// Half-angle of the port bore's draft, in degrees, measured from the
    /// bore axis. At distance `d` from the route end the radius is
    /// `portBoreDiameter/2 + d * tan(portBoreTaperDegrees)`. Set to 0 for a
    /// straight (cylindrical) bore.
    var portBoreTaperDegrees: Double

    /// Thickness of the silicone sheet sandwiched between the two plates.
    var siliconeThickness: Double

    /// Diameter of the transistor dimple — the cup the silicone deflects into.
    /// Drives the radius of the dome-shaped cavity (revolved spherical cap).
    var dimpleDiameter: Double

    /// Legacy flat-cylinder dimple depth. Retained for codable backwards
    /// compatibility; the dome geometry derives depth from `dimpleDiameter`
    /// and `dimpleSphereOffset` instead.
    var dimpleDepth: Double

    /// Distance from the plate's silicone-facing surface to the centre of the
    /// dome's defining sphere, measured into the plate body. Matches the
    /// Fusion 360 source sketch: revolving the disk's larger cap (the part on
    /// the cavity side of the surface line) around the vertical axis. Depth
    /// of the cavity into the plate is `dimpleDiameter/2 + dimpleSphereOffset`.
    var dimpleSphereOffset: Double

    /// Diameter of the source/drain pad sphere. The pads are two halves of a
    /// sphere centred at the gate on the opposite plate's silicone face,
    /// split by the central strip. Should be < the gate dome's face-opening
    /// diameter so the pads fit inside the gate footprint.
    var padsDiameter: Double

    /// Width of the central strip separating the two source/drain pads along
    /// the source-drain (local X) axis. Each pad occupies the region
    /// `|local x| > padsSeparation/2` inside the pad sphere.
    var padsSeparation: Double

    /// Distance from the gate centre to each source/drain tube (drop bore)
    /// along the source-drain (local X) axis. Replaces the previously
    /// hardcoded 1.5 mm halfPitch in the transistor footprint, so the routed
    /// pin positions, DRC, placement bounds and CAD geometry all track it.
    var padsOffset: Double

    /// Fillet radius applied to the sharp edge between each pad's spherical
    /// surface and its flat face (the chord shared with the central strip).
    /// Set to 0 to leave the edge sharp. Bounded by `(padsDiameter/2 -
    /// padsSeparation/2) / 2`; values outside that range fall back to the
    /// sharp construction. Matches the R0.50 fillet in the Fusion source
    /// sketch — softens the print so the corner isn't a stress riser.
    var padsFilletRadius: Double

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

    /// Fillet radius applied to the four vertical corner edges of each
    /// plate — softens the corners viewed from above so the printer doesn't
    /// have to resolve a perfect 90° corner. Runs full plate height; the
    /// top and bottom faces both become rounded rectangles of this radius.
    /// Set to 0 for square corners (default).
    var plateCornerFillet: Double

    static let defaults = ManufacturingConstants(
        plateThickness: 5.0,
        channelDiameter: 1.5,
        portBoreDiameter: 1.7,
        portBoreTaperDegrees: 1.0,
        siliconeThickness: 0.5,
        dimpleDiameter: 5.0,
        dimpleDepth: 1.0,
        dimpleSphereOffset: 1.0,
        padsDiameter: 4.0,
        padsSeparation: 1.0,
        padsOffset: 1.5,
        padsFilletRadius: 0.5,
        gridPitch: 1.0,
        minChannelSpacing: 1.5,
        resistorChannelDiameter: 0.5,
        interLayerWall: 0.6,
        plateCornerFillet: 0
    )

    // Codable hand-rolled so older .vpcb files (written before
    // resistorChannelDiameter or interLayerWall existed) still decode — they
    // get the default for any field they didn't write.
    private enum CodingKeys: String, CodingKey {
        case plateThickness, channelDiameter, portBoreDiameter, portBoreTaperDegrees
        case siliconeThickness
        case dimpleDiameter, dimpleDepth, dimpleSphereOffset
        case padsDiameter, padsSeparation, padsOffset, padsFilletRadius
        case gridPitch, minChannelSpacing
        case resistorChannelDiameter, interLayerWall
        case plateCornerFillet
    }

    init(plateThickness: Double, channelDiameter: Double,
         portBoreDiameter: Double, portBoreTaperDegrees: Double,
         siliconeThickness: Double, dimpleDiameter: Double, dimpleDepth: Double,
         dimpleSphereOffset: Double,
         padsDiameter: Double, padsSeparation: Double, padsOffset: Double,
         padsFilletRadius: Double,
         gridPitch: Double, minChannelSpacing: Double, resistorChannelDiameter: Double,
         interLayerWall: Double, plateCornerFillet: Double) {
        self.plateThickness = plateThickness
        self.channelDiameter = channelDiameter
        self.portBoreDiameter = portBoreDiameter
        self.portBoreTaperDegrees = portBoreTaperDegrees
        self.siliconeThickness = siliconeThickness
        self.dimpleDiameter = dimpleDiameter
        self.dimpleDepth = dimpleDepth
        self.dimpleSphereOffset = dimpleSphereOffset
        self.padsDiameter = padsDiameter
        self.padsSeparation = padsSeparation
        self.padsOffset = padsOffset
        self.padsFilletRadius = padsFilletRadius
        self.gridPitch = gridPitch
        self.minChannelSpacing = minChannelSpacing
        self.resistorChannelDiameter = resistorChannelDiameter
        self.interLayerWall = interLayerWall
        self.plateCornerFillet = plateCornerFillet
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
        portBoreTaperDegrees = try c.decodeIfPresent(Double.self,
                                                     forKey: .portBoreTaperDegrees) ?? 1.0
        siliconeThickness = try c.decode(Double.self, forKey: .siliconeThickness)
        dimpleDiameter = try c.decode(Double.self, forKey: .dimpleDiameter)
        dimpleDepth = try c.decode(Double.self, forKey: .dimpleDepth)
        dimpleSphereOffset = try c.decodeIfPresent(Double.self,
                                                   forKey: .dimpleSphereOffset) ?? 1.0
        padsDiameter = try c.decodeIfPresent(Double.self,
                                             forKey: .padsDiameter) ?? 4.0
        padsSeparation = try c.decodeIfPresent(Double.self,
                                               forKey: .padsSeparation) ?? 1.0
        padsOffset = try c.decodeIfPresent(Double.self,
                                           forKey: .padsOffset) ?? 1.5
        padsFilletRadius = try c.decodeIfPresent(Double.self,
                                                 forKey: .padsFilletRadius) ?? 0.5
        gridPitch = try c.decode(Double.self, forKey: .gridPitch)
        minChannelSpacing = try c.decode(Double.self, forKey: .minChannelSpacing)
        resistorChannelDiameter = try c.decodeIfPresent(Double.self,
                                                       forKey: .resistorChannelDiameter) ?? 0.5
        interLayerWall = try c.decodeIfPresent(Double.self,
                                              forKey: .interLayerWall) ?? 0.6
        plateCornerFillet = try c.decodeIfPresent(Double.self,
                                                forKey: .plateCornerFillet) ?? 0
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
