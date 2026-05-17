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
        // Index reusable parts before any window opens so the schematic
        // palette is populated on first paint.
        PartsLibrary.shared.reload()
        #if DEBUG
        SelfTest.runJSONRoundTrip()
        SelfTest.runSTLSmokeTest()
        SelfTest.runNestedSubpartFlatten()
        #endif
    }

    var body: some Scene {
        // File → New seeds the inverter sample instead of a blank doc — gives
        // every new window a known-good circuit + buildable STL out of the box.
        DocumentGroup(newDocument: VPCBDocument(circuit: Examples.inverter())) { config in
            DocumentView(document: config.$document)
        }
        .commands {
            CommandMenu("Library") {
                Button("Reload Library") {
                    PartsLibrary.shared.reload()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Reveal Parts Folder in Finder") {
                    let url = PartsLibrary.folderURL
                    try? FileManager.default.createDirectory(
                        at: url, withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}
