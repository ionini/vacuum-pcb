import Testing
import Foundation
@testable import Vacuum_PCB

/// Copy/paste of manufacturing parameters between documents. The important
/// invariants: the field table covers every constant (otherwise a parameter
/// silently can't be pasted), a partial paste touches only the checked
/// fields, and the paste goes through the same clamping the inspector's Apply
/// uses.
@MainActor
struct ManufacturingClipboardTests {

    @Test("Field descriptors cover every stored constant")
    func fieldTableCoversEveryEncodedKey() throws {
        // The encoded keys are the ground truth for "what's in the struct":
        // `CodingKeys` names match the property names one-for-one, so any new
        // constant shows up here and must have a descriptor.
        let data = try JSONEncoder().encode(ManufacturingConstants.defaults)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedKeys = Set(json.keys)
        let describedKeys = Set(ManufacturingParameterField.all.map(\.id))

        #expect(encodedKeys.subtracting(describedKeys).isEmpty,
                "constants with no ManufacturingParameterField row: \(encodedKeys.subtracting(describedKeys).sorted())")
        #expect(describedKeys.subtracting(encodedKeys).isEmpty,
                "field rows naming constants that no longer exist: \(describedKeys.subtracting(encodedKeys).sorted())")
        // No duplicate ids — the sheet keys its selection by id.
        #expect(describedKeys.count == ManufacturingParameterField.all.count)
    }

    @Test("differingFields lists exactly what changed")
    func differingFieldsFindsChanges() {
        let current = ManufacturingConstants.defaults
        var incoming = current
        incoming.channelDiameter += 0.4
        incoming.flatBottomChannels.toggle()

        let ids = Set(current.differingFields(from: incoming).map(\.id))
        #expect(ids == ["channelDiameter", "flatBottomChannels"])
        #expect(current.differingFields(from: current).isEmpty)
    }

    @Test("Unchecked parameters keep the destination's values")
    func partialMergeTakesOnlySelectedFields() {
        let current = ManufacturingConstants.defaults
        var incoming = current
        incoming.channelDiameter = 2.5
        incoming.plateThickness = 5.0
        incoming.flatBottomChannels = false

        let merged = current.merging(incoming, fields: ["channelDiameter",
                                                        "flatBottomChannels"])
        #expect(merged.channelDiameter == 2.5)
        #expect(merged.flatBottomChannels == false)
        // Not selected → destination value survives.
        #expect(merged.plateThickness == current.plateThickness)
        // Nothing else drifted (the merge is copy-and-mutate, not a
        // memberwise rebuild).
        #expect(merged == current.merging(incoming, fields: ["channelDiameter",
                                                            "flatBottomChannels"]))
        #expect(current.merging(incoming, fields: []) == current)
    }

    @Test("Pasting everything reproduces the source constants")
    func fullMergeEqualsSource() {
        let current = ManufacturingConstants.defaults
        var incoming = current
        // Nudge every numeric field and flip the flag, so a missing field
        // descriptor would leave a residue behind.
        incoming.plateThickness += 1
        incoming.channelDiameter += 0.2
        incoming.portBoreDiameter += 0.2
        incoming.portBoreTaperDegrees += 1
        incoming.siliconeThickness += 0.4
        incoming.dimpleDiameter += 1
        incoming.dimpleDepth += 0.5
        incoming.dimpleSphereOffset += 0.5
        incoming.padsDiameter += 0.5
        incoming.padsSeparation += 0.5
        incoming.padsOffset += 0.1
        incoming.padsFilletRadius += 0.1
        incoming.gridPitch += 0.5
        incoming.minChannelSpacing += 0.5
        incoming.resistorChannelDiameter += 0.1
        incoming.smoothResistors.toggle()
        incoming.interLayerWall += 0.25
        incoming.testPointLabelSize += 1
        incoming.plateCornerFillet += 1
        incoming.ledDimpleDiameter += 1
        incoming.ledDimpleDepth += 0.5
        incoming.screwProtrusion += 0.5
        incoming.screwDomeBaseDiameter += 1
        incoming.screwHeadDepth += 0.5
        incoming.screwNutDepth += 0.5
        incoming.screwThroughDiameter += 0.2
        incoming.stencilThickness += 0.1
        incoming.stencilViaPadding += 0.5
        incoming.stencilScrewPadding += 0.5
        incoming.connectorGasketWidth += 0.5
        incoming.connectorGasketViaPadding += 0.5
        incoming.connectorGasketScrewPadding += 0.5
        incoming.connectorPadding += 2
        incoming.castingMargin += 1
        incoming.moldWallThickness += 1
        incoming.minWallThickness += 0.1
        incoming.preferredWallThickness += 0.1
        incoming.flatBottomChannels.toggle()
        incoming.modifierMarginXY += 0.5
        incoming.modifierMarginZ += 0.2
        incoming.resistorInfillDensity += 5
        incoming.resistorInfillPattern += "-x"

        // Every field differs, so a full selection must land the source
        // verbatim — this is the check that catches a constant missing from
        // `all` (it would keep the destination's value instead).
        let allIDs = Set(ManufacturingParameterField.all.map(\.id))
        #expect(current.differingFields(from: incoming).count == allIDs.count)
        #expect(current.merging(incoming, fields: allIDs) == incoming)
    }

    @Test("Commit clamps a nonsense pasted value")
    func commitSanitizes() {
        var document = VPCBDocument()
        var incoming = document.circuit.manufacturing
        incoming.channelDiameter = 0          // below the 0.05 floor
        incoming.stencilViaPadding = 9        // above the 2 mm ceiling
        incoming.plateThickness = 4.2         // legitimate

        ManufacturingActions.commit(incoming, to: &document)

        #expect(document.circuit.manufacturing.channelDiameter == 0.05)
        #expect(document.circuit.manufacturing.stencilViaPadding == 2.0)
        #expect(document.circuit.manufacturing.plateThickness == 4.2)
    }

    @Test("Clipboard hands the payload to a paste request")
    func clipboardRoundTrip() {
        let clipboard = ManufacturingClipboard.shared
        var copied = ManufacturingConstants.defaults
        copied.padsOffset = 1.75
        clipboard.store(copied, from: "BusTester")

        #expect(clipboard.hasContent)
        let request = ManufacturingPasteRequest.fromClipboard()
        #expect(request?.incoming.padsOffset == 1.75)
        #expect(request?.sourceName == "BusTester")
    }
}
