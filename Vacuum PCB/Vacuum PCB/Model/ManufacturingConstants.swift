import Foundation

struct ManufacturingConstants: Codable, Hashable {
    var plateThickness: Double
    var channelWidth: Double
    var channelHeight: Double
    var portBoreDiameter: Double
    var siliconeThickness: Double
    var dimpleDiameter: Double
    var dimpleDepth: Double
    var sourceDrainHoleDiameter: Double
    var sourceDrainHolePitch: Double
    var gridPitch: Double
    var bendFilletRadius: Double
    var minChannelSpacing: Double

    static let defaults = ManufacturingConstants(
        plateThickness: 4.0,
        channelWidth: 1.5,
        channelHeight: 1.5,
        portBoreDiameter: 1.6,
        siliconeThickness: 0.5,
        dimpleDiameter: 5.0,
        dimpleDepth: 1.0,
        sourceDrainHoleDiameter: 1.5,
        sourceDrainHolePitch: 3.0,
        gridPitch: 1.0,
        bendFilletRadius: 0.75,
        minChannelSpacing: 1.5
    )
}
