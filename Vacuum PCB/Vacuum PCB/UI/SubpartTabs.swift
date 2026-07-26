import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Opening library part files as native macOS window tabs. Shared by the
/// InspectorStrip's per-subpart "Open in Tab" button and the View-menu
/// "Open All Subparts as Tabs" command, so both re-home windows the same
/// way. Window tabs are a Mac concept; iPad reaches part files through
/// the document browser, so everything AppKit-flavoured is gated.
enum SubpartTabs {
    /// Every library file reachable from `circuit`'s subpart instances,
    /// depth-first and deduplicated: A importing B importing C yields
    /// B's file then C's, all the way down to parts with no subparts of
    /// their own. Resolution goes through the live library (these are the
    /// files that would open), and the visited set breaks reference
    /// cycles between library files.
    static func transitivePartRefs(in circuit: CircuitDocument) -> [String] {
        var ordered: [String] = []
        var visited = Set<String>()
        func visit(_ doc: CircuitDocument) {
            for c in doc.logic.components where c.kind == .subpart {
                guard let filename = c.partRef, visited.insert(filename).inserted else { continue }
                ordered.append(filename)
                if let part = PartsLibrary.shared.part(named: filename) {
                    visit(part.document)
                }
            }
        }
        visit(circuit)
        return ordered
    }

    #if canImport(AppKit)
    /// Open one library file via the DocumentGroup, then re-home the new
    /// window as a tab of `host`. If the file is already open we just let
    /// `openDocument` bring its existing window forward instead of moving
    /// it.
    @MainActor
    static func open(filename: String, host: NSWindow?, openDocument: OpenDocumentAction) async {
        let url = PartsLibrary.folderURL.appendingPathComponent(filename).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let alreadyOpen = NSApp.windows.contains { $0.representedURL?.standardizedFileURL == url }
        guard (try? await openDocument(at: url)) != nil else { return }
        guard !alreadyOpen, let host else { return }
        // The window may register a beat after openDocument returns —
        // poll briefly rather than racing it.
        for _ in 0..<10 {
            if let opened = NSApp.windows.first(where: {
                $0.representedURL?.standardizedFileURL == url
            }), opened !== host {
                host.addTabbedWindow(opened, ordered: .above)
                opened.makeKeyAndOrderFront(nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// View-menu bulk open: one tab per library file reachable from
    /// `circuit`, opened sequentially so each lands as a tab before the
    /// next `openDocument` fires. Ends by fronting the host document again
    /// so the user starts from where they invoked the command.
    @MainActor
    static func openAll(from circuit: CircuitDocument, openDocument: OpenDocumentAction) {
        let filenames = transitivePartRefs(in: circuit)
        guard !filenames.isEmpty else { return }
        let host = NSApp.keyWindow
        Task { @MainActor in
            for filename in filenames {
                await open(filename: filename, host: host, openDocument: openDocument)
            }
            host?.makeKeyAndOrderFront(nil)
        }
    }
    #endif
}

#if canImport(AppKit)
/// Focused-scene action behind the View-menu "Open All Subparts as Tabs"
/// command: the frontmost DocumentView publishes it, the menu item calls
/// it. Equality is by `enabled` alone — the closure is rebuilt on every
/// render but only captures stable handles (the document binding and the
/// environment's openDocument action), so menu validation only needs to
/// know whether the doc has any subparts to open.
struct OpenAllSubpartTabsAction: Equatable {
    let enabled: Bool
    let run: @MainActor () -> Void
    static func == (a: Self, b: Self) -> Bool { a.enabled == b.enabled }
}

struct OpenAllSubpartTabsKey: FocusedValueKey {
    typealias Value = OpenAllSubpartTabsAction
}

extension FocusedValues {
    var openAllSubpartTabs: OpenAllSubpartTabsAction? {
        get { self[OpenAllSubpartTabsKey.self] }
        set { self[OpenAllSubpartTabsKey.self] = newValue }
    }
}
#endif
