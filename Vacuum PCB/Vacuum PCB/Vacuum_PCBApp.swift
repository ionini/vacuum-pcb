//
//  Vacuum_PCBApp.swift
//  Vacuum PCB
//
//  Created by Jonatan Zelig Nielavitzky on 14/05/2026.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@main
struct Vacuum_PCBApp: App {
    init() {
        // Index reusable parts before any window opens so the schematic
        // palette is populated on first paint.
        PartsLibrary.shared.reload()
    }

    var body: some Scene {
        DocumentGroup(newDocument: VPCBDocument()) { config in
            DocumentView(document: config.$document)
        }
        // SwiftUI's intrinsic-size default for document windows was small
        // enough that the Physical bottom strip needed scrolling on every
        // launch. Pick a size that gives the canvas room and matches what
        // a 13" laptop can still display.
        .defaultSize(width: 1400, height: 900)
        #if canImport(AppKit)
        .commands {
            // Adds the standard View > Show/Hide Inspector menu item with
            // its ⌃⌘I shortcut, wired to the document's `.inspector(...)`.
            InspectorCommands()

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
        #endif
    }
}
