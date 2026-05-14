//
//  Vacuum_PCBApp.swift
//  Vacuum PCB
//
//  Created by Jonatan Zelig Nielavitzky on 14/05/2026.
//

import SwiftUI

@main
struct Vacuum_PCBApp: App {
    init() {
        #if DEBUG
        SelfTest.runJSONRoundTrip()
        SelfTest.runSTLSmokeTest()
        #endif
    }

    var body: some Scene {
        DocumentGroup(newDocument: VPCBDocument()) { config in
            DocumentView(document: config.$document)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Inverter Sample") {
                    openInverterSample()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
    }

    /// Convenience: drop the bundled inverter into a temp file and open it via the
    /// document controller, since DocumentGroup doesn't let us seed a new document
    /// directly. The user can then Save As to wherever they want.
    private func openInverterSample() {
        let doc = Examples.inverter()
        guard let data = try? doc.encoded() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Inverter Sample.vpcb")
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("Could not write inverter sample: \(error)")
            return
        }
        NSDocumentController.shared.openDocument(
            withContentsOf: url, display: true
        ) { _, _, _ in }
    }
}
