import Testing
import Foundation
@testable import Vacuum_PCB

/// `rebased(onto:baseline:)` — the merge the Manufacturing inspector runs
/// when the document changes underneath an in-progress draft (parameter
/// paste, envelope slider, Undo). The invariants: untouched fields follow
/// the document immediately, fields the user edited keep the user's value,
/// and "edited" is judged against the baseline the draft was synced from —
/// never against the new document.
@MainActor
struct ManufacturingDraftRebaseTests {

    @Test("Clean draft follows the document completely (the Undo case)")
    func cleanDraftAdoptsDocument() {
        // After Apply the draft and baseline both equal the document. ⌘Z
        // then rewinds the document; the rebased draft must follow it so
        // the panel visibly reverts instead of showing the undone values.
        let baseline = ManufacturingConstants.defaults
        var reverted = baseline
        reverted.channelDiameter += 0.7
        reverted.flatBottomChannels.toggle()

        let rebased = baseline.rebased(onto: reverted, baseline: baseline)
        #expect(rebased == reverted)
    }

    @Test("User edit survives an external change to another field")
    func userEditSurvivesExternalChange() {
        let baseline = ManufacturingConstants.defaults
        var draft = baseline
        draft.channelDiameter = 2.4          // user is editing this

        var document = baseline              // paste lands two other fields
        document.plateThickness = 6.5
        document.padsOffset = 3.1

        let rebased = draft.rebased(onto: document, baseline: baseline)
        #expect(rebased.channelDiameter == 2.4)
        #expect(rebased.plateThickness == 6.5)
        #expect(rebased.padsOffset == 3.1)
        // Nothing else drifted.
        var expected = document
        expected.channelDiameter = 2.4
        #expect(rebased == expected)
    }

    @Test("Draft wins when the user and the document changed the same field")
    func draftWinsConflicts() {
        // The field shows what Apply will write, so the user's in-progress
        // value must stay visible even if a paste also touched that field.
        let baseline = ManufacturingConstants.defaults
        var draft = baseline
        draft.gridPitch = 0.25

        var document = baseline
        document.gridPitch = 2.0
        document.stencilViaPadding = 0.8

        let rebased = draft.rebased(onto: document, baseline: baseline)
        #expect(rebased.gridPitch == 0.25)
        #expect(rebased.stencilViaPadding == 0.8)
    }

    @Test("Flag fields rebase like numbers")
    func flagFieldsRebase() {
        let baseline = ManufacturingConstants.defaults
        var draft = baseline
        draft.flatBottomChannels.toggle()    // user flipped the toggle

        var document = baseline
        document.moldWallThickness += 1.0

        let rebased = draft.rebased(onto: document, baseline: baseline)
        #expect(rebased.flatBottomChannels == draft.flatBottomChannels)
        #expect(rebased.moldWallThickness == document.moldWallThickness)
    }

    @Test("Identical document is a no-op")
    func identityRebase() {
        let baseline = ManufacturingConstants.defaults
        var draft = baseline
        draft.screwHeadDepth = 4.2

        let rebased = draft.rebased(onto: baseline, baseline: baseline)
        #expect(rebased == draft)
    }
}
