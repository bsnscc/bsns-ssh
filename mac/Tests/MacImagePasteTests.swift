import AppKit
import XCTest
import BsnsSSHCore

@MainActor
final class MacImagePasteTests: XCTestCase {
    private func withClipboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    private func bitmap() -> NSBitmapImageRep {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<3 { for y in 0..<2 { image.setColor(NSColor(deviceRed: 0, green: 0.7, blue: 0.6, alpha: 1), atX: x, y: y) } }
        return image
    }

    func testPNGIsPreservedAndDispatchedBeforeText() {
        withClipboard { pasteboard in
            let data = bitmap().representation(using: .png, properties: [:])!
            pasteboard.setData(data, forType: .png)
            pasteboard.setString("image caption", forType: .string)
            let view = MacTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
            var received: Data?
            view.onImagePasted = { bytes, ext in received = bytes; XCTAssertEqual(ext, "png") }
            XCTAssertTrue(view.pasteImage(from: pasteboard))
            XCTAssertEqual(received, data)
        }
    }

    func testJPEGKeepsOriginalEncoding() {
        withClipboard { pasteboard in
            let data = bitmap().representation(using: .jpeg, properties: [:])!
            pasteboard.setData(data, forType: .init("public.jpeg"))
            let image = MacClipboardImage.read(from: pasteboard)
            XCTAssertEqual(image?.data, data)
            XCTAssertEqual(image?.ext, "jpg")
        }
    }

    func testTIFFScreenshotConvertsToPNG() throws {
        try withClipboard { pasteboard in
            pasteboard.setData(bitmap().tiffRepresentation!, forType: .tiff)
            let image = try XCTUnwrap(MacClipboardImage.read(from: pasteboard))
            XCTAssertEqual(image.ext, "png")
            XCTAssertEqual(Array(image.data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: image.data))
            XCTAssertEqual(decoded.pixelsWide, 3)
            XCTAssertEqual(decoded.pixelsHigh, 2)
        }
    }

    func testTextAndFileURLsDoNotTriggerImagePaste() {
        withClipboard { pasteboard in
            let view = MacTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
            view.onImagePasted = { _, _ in XCTFail("Text must use the terminal's normal paste path") }
            pasteboard.setString("echo hello\n", forType: .string)
            XCTAssertFalse(view.pasteImage(from: pasteboard))
            pasteboard.clearContents()
            pasteboard.setString("file:///tmp/picture.png", forType: .fileURL)
            XCTAssertFalse(view.pasteImage(from: pasteboard))
        }
    }

    func testFinderFilePasteUsesFileURLInsteadOfFilenameText() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("picture-\(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        withClipboard { pasteboard in
            pasteboard.writeObjects([file as NSURL])
            pasteboard.setString(file.lastPathComponent, forType: .string)
            let view = MacTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
            var received: [URL] = []
            view.onFilesReceived = { received = $0 }
            XCTAssertTrue(view.pasteFiles(from: pasteboard))
            XCTAssertEqual(received, [file])
        }
    }

    func testInvalidImageDataDoesNotSwallowTextPaste() {
        withClipboard { pasteboard in
            pasteboard.setData(Data("broken image".utf8), forType: .png)
            pasteboard.setString("ordinary text", forType: .string)
            XCTAssertNil(MacClipboardImage.read(from: pasteboard))
        }
    }

    func testLocalImageIsPrivateAndPathCanBeQuoted() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let data = bitmap().representation(using: .png, properties: [:])!
        let image = MacClipboardImage(data: data, ext: "png")
        let file = try image.saveLocally(directory: "~/screenshots with spaces", home: home)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(file.deletingLastPathComponent(), home.appendingPathComponent("screenshots with spaces", isDirectory: true))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(WorkspaceCommand.quoted(file.path), "\"" + file.path + "\"")
        let next = try image.saveLocally(directory: "~/screenshots with spaces", home: home)
        XCTAssertNotEqual(next, file)
    }

    func testEmptyDirectoryUsesDefault() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let image = MacClipboardImage(data: Data([1, 2, 3]), ext: "png")
        let file = try image.saveLocally(directory: "  ", home: home)
        XCTAssertEqual(file.deletingLastPathComponent(), home.appendingPathComponent(".bsns-ssh-drops", isDirectory: true))
    }
}
