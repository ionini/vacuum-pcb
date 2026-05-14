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
        // Until iter 2 adds a schematic editor, a blank document is useless — File → New
        // seeds the inverter sample so the preview has something to render immediately.
        DocumentGroup(newDocument: VPCBDocument(circuit: Examples.inverter())) { config in
            DocumentView(document: config.$document)
        }
    }
}
