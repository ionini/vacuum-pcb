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
        #if canImport(AppKit)
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
        #endif
    }
}
