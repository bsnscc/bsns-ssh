import AppKit
import SwiftTerm
import BsnsSSHCore

/// Keep image handling ahead of text: copied pictures can carry both.
class MacTerminalView: TerminalView {
    var onImagePasted: ((Data, String) -> Void)?
    var onFilesReceived: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func viewWillDraw() {
        // Use AppKit's normal layer redraw behavior. The terminal's legacy
        // partial-redraw workaround changes the layer's contents format during
        // drawing, which is fragile when SwiftUI rehosts a cached surface.
        disableFullRedrawOnAnyChanges = false
        super.viewWillDraw()
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        // A tmux repaint may arrive in several feeds. Paint the entire visible
        // buffer when SwiftTerm's coalesced update fires, so a narrow dirty band
        // cannot leave the rest of a newly attached layer blank or stale.
        // This stays event-driven; idle sessions do not acquire a redraw timer.
        super.setNeedsDisplay(bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsDisplay = true }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil { needsDisplay = true }
    }

    override func paste(_ sender: Any) {
        if pasteFiles(from: .general) { return }
        if pasteImage(from: .general) { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MacClipboardImage.fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = MacClipboardImage.fileURLs(from: sender.draggingPasteboard)
        guard !files.isEmpty else { return false }
        onFilesReceived?(files)
        return true
    }

    @discardableResult
    func pasteImage(from pasteboard: NSPasteboard) -> Bool {
        guard let image = MacClipboardImage.read(from: pasteboard) else { return false }
        onImagePasted?(image.data, image.ext)
        return true
    }

    @discardableResult
    func pasteFiles(from pasteboard: NSPasteboard) -> Bool {
        let files = MacClipboardImage.fileURLs(from: pasteboard)
        guard !files.isEmpty else { return false }
        onFilesReceived?(files)
        return true
    }
}

struct MacClipboardImage {
    let data: Data
    let ext: String

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self],
                                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { $0.isFileURL }
    }

    static func read(from pasteboard: NSPasteboard) -> Self? {
        // Preserve PNG/JPEG bytes. Screenshots and copied selections from Mac
        // image editors often offer TIFF instead; encode those as PNG.
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"),
                            (NSPasteboard.PasteboardType("public.jpeg"), "jpg")] {
            if let data = pasteboard.data(forType: type), NSBitmapImageRep(data: data) != nil {
                return Self(data: data, ext: ext)
            }
        }
        // Only inline image data. Do not dereference file URLs or web URLs
        // merely because they could point to an image.
        guard let tiff = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return Self(data: png, ext: "png")
    }

    /// A local shell needs a local file, rather than an SFTP connection.
    func saveLocally(directory: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let configured = directory.trimmingCharacters(in: .whitespaces)
        let raw = configured.isEmpty ? "~/.bsns-ssh-drops" : configured
        let folder: URL
        if raw.hasPrefix("/") {
            folder = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            let relative = raw.hasPrefix("~") ? String(raw.dropFirst()).drop(while: { $0 == "/" }) : raw[...]
            folder = home.appendingPathComponent(String(relative), isDirectory: true)
        }
        guard WorkspaceCommand.quoted(folder.path) != nil, ["png", "jpg"].contains(ext) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("shot-\(UUID().uuidString.lowercased()).\(ext)")
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
}
