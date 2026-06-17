// swift-tools-version: 5.9
import PackageDescription

// Headless validation CLI for Vacuum PCB.
//
// Strategy: compile the app's entire source tree into one executable target
// alongside the `cli/` driver, linking Euclid as a local SwiftPM package. The
// Model/CAD layers are tightly entangled (e.g. Ratsnest → PlateBuilder →
// STLExportDocument), so cherry-picking files is brittle; compiling everything
// mirrors the Xcode target exactly and avoids drift. SwiftUI/AppKit symbols
// link fine in a command-line tool — we simply never instantiate a view. Only
// the `@main` app entry and non-code resources are excluded. Builds with plain
// `swift build`, independent of the Xcode project.
let package = Package(
    name: "VacuumCLI",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../Euclid")
    ],
    // Match the app's deployment target: some UI files call macOS 26-only APIs
    // (e.g. `glassEffect`) unconditionally. `.v14` etc. don't reach 26, so use
    // the version-string form.
    targets: [
        .executableTarget(
            name: "vacuum-cli",
            dependencies: [.product(name: "Euclid", package: "Euclid")],
            path: ".",
            exclude: [
                // Docs living next to the CLI sources.
                "cli/README.md",
                // The app's own @main entry would collide with the CLI's.
                "Vacuum PCB/Vacuum PCB/Vacuum_PCBApp.swift",
                // App bundle resources, not compilable sources.
                "Vacuum PCB/Vacuum PCB/Info.plist",
                "Vacuum PCB/Vacuum PCB/Assets.xcassets",
                "Vacuum PCB/Vacuum PCB/Vacuum PCB.entitlements",
                "Vacuum PCB/Vacuum PCB/Examples",
                // The app's XCTest/Swift Testing target — not part of the CLI.
                "Vacuum PCB/Vacuum PCBTests",
                // Everything under the repo root that isn't our source.
                "Vacuum PCB/Vacuum PCB.xcodeproj",
                "README.md",
                "LICENSE",
                "DESIGN.md",
                "ASSEMBLY_PLAN.md",
                "CONNECTOR_PLAN.md",
                "SUBPART_FLIP_PLAN.md",
                "EUCLID_PERF.md",
                "Vacuum PCB.icon",
                "Icon 2.icon",
            ],
            sources: [
                "Vacuum PCB/Vacuum PCB",
                "cli",
            ]
        )
    ]
)
