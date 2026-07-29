import Combine
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// In-process clipboard for a design's manufacturing constants: copy them in
/// one document window, paste them into another.
///
/// Like `SchematicClipboard`, there's no `NSPasteboard` bridge — the payload
/// is a plain value held by a singleton, so it's shared by every open window
/// but doesn't survive relaunch and doesn't clobber the user's text clipboard
/// with a wall of JSON.
final class ManufacturingClipboard: ObservableObject {
    static let shared = ManufacturingClipboard()

    @Published private(set) var payload: ManufacturingConstants?
    /// Document the payload came from, shown in the paste sheet's subtitle so
    /// the user can tell *which* design's numbers they're about to apply.
    @Published private(set) var sourceName: String?

    var hasContent: Bool { payload != nil }

    func store(_ constants: ManufacturingConstants, from name: String?) {
        payload = constants
        sourceName = name
    }

    /// Filename (sans extension) of the frontmost document window, used to
    /// label a copy. macOS only — on iPad the sheet just says "another
    /// design".
    static func frontmostDocumentName() -> String? {
        #if canImport(AppKit)
        guard let url = NSApp.keyWindow?.representedURL else { return nil }
        return url.deletingPathExtension().lastPathComponent
        #else
        return nil
        #endif
    }
}
