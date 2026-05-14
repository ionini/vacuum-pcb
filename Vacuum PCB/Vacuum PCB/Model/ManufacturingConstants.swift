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

    static let defaults = ManufacturingConstants(
        plateThickness: 5.0,
        channelDiameter: 1.5,
        portBoreDiameter: 1.6,
        siliconeThickness: 0.5,
        dimpleDiameter: 5.0,
        dimpleDepth: 1.0,
        gridPitch: 1.0,
        minChannelSpacing: 1.5
    )
}
