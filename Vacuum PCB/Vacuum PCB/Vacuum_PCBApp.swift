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
        // File → New seeds the inverter sample instead of a blank doc — gives
        // every new window a known-good circuit + buildable STL out of the box.
        DocumentGroup(newDocument: VPCBDocument(circuit: Examples.inverter())) { config in
            DocumentView(document: config.$document)
        }
    }
}
