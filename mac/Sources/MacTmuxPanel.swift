import SwiftUI
import AppKit
import BsnsSSHCore

/// tmux beside the terminal: the session's windows, and the active pane's whole
/// history as ordinary text — scrollable, searchable (⌘F), selectable — over a
/// second SSH connection held for as long as the panel is open.
struct MacTmuxPanel: View {
    @State private var model: TmuxPanelModel
    @State private var text = MacHistoryController()
    @State private var showHistory: Bool
    @State private var notice: String?
    @AppStorage(SettingsKey.promptPattern) private var promptPattern = PromptScan.defaultPattern
    @Environment(\.dismiss) private var dismiss

    init(session: TerminalSession, showHistory: Bool) {
        _model = State(initialValue: TmuxPanelModel(session: session))
        _showHistory = State(initialValue: showHistory)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $showHistory) {
                    Text("Windows").tag(false)
                    Text("History").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                if showHistory, case .ready = model.state {
                    Button { text.jumpToPrompt(previous: true) } label: { Image(systemName: "chevron.up") }
                        .help("Previous prompt").disabled(!text.hasPrompts)
                    Button { text.jumpToPrompt(previous: false) } label: { Image(systemName: "chevron.down") }
                        .help("Next prompt").disabled(!text.hasPrompts)
                    Button("Copy Last Output") { copyLastOutput() }.disabled(!text.hasPrompts)
                    Button("Load Everything") { Task { await model.loadHistory(lines: TmuxCommand.maxHistoryLines) } }
                }
                if !showHistory, case .ready = model.state {
                    Button("New Window") { Task { if await model.newWindow() { dismiss() } } }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 480)
        .task {
            await model.connect()
            await load()
        }
        .onChange(of: showHistory) { _, _ in Task { await load() } }
        .onDisappear { model.close() }
    }

    private func load() async {
        if showHistory {
            if model.history == nil { await model.loadHistory(lines: TmuxPanelModel.defaultHistoryLines) }
        } else {
            await model.loadWindows()
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .connecting:
            ProgressView("Connecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            failure(message)
        case .ready:
            if showHistory {
                if let history = model.history {
                    MacHistoryText(text: history, paneWidth: model.historyWidth, promptPattern: promptPattern, controller: text)
                } else if let error = model.error {
                    failure(error)
                } else {
                    ProgressView("Reading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                windowList
            }
        }
    }

    private var windowList: some View {
        List {
            if let error = model.error { Text(error).foregroundStyle(.red) }
            if model.windows.isEmpty, model.error == nil, !model.busy {
                Text("No windows found.").foregroundStyle(.secondary)
            }
            ForEach(model.windows) { window in
                Button {
                    Task { if await model.select(window) { dismiss() } }
                } label: {
                    HStack(spacing: 12) {
                        Text("\(window.index)").monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 22, alignment: .trailing)
                        Text(window.name.isEmpty ? window.command : window.name).font(.body.monospaced())
                        if !window.name.isEmpty, window.command != window.name {
                            Text(window.command).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if window.isActive { Image(systemName: "checkmark").foregroundStyle(Brand.accent) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
            Button("Try Again") { Task { await model.connect(); await load() } }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyLastOutput() {
        guard let output = text.lastOutput() else { notice = "No command output found"; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        let lines = output.split(whereSeparator: \.isNewline).count
        notice = "Copied \(lines) line\(lines == 1 ? "" : "s")"
    }
}

/// Lets the panel's buttons drive the text view: prompt jumps, copy.
@MainActor
@Observable
final class MacHistoryController {
    @ObservationIgnored fileprivate weak var textView: NSTextView?
    @ObservationIgnored fileprivate var lineStarts: [Int] = []
    @ObservationIgnored fileprivate var lines: [Substring] = []
    @ObservationIgnored fileprivate var scan: PromptScan?
    @ObservationIgnored fileprivate var paneWidth: Int?
    fileprivate(set) var promptLines: [Int] = []

    var hasPrompts: Bool { !promptLines.isEmpty }

    fileprivate func index(_ text: String, pattern: String, paneWidth: Int?) {
        self.paneWidth = paneWidth
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }
        lineStarts = starts
        scan = PromptScan(pattern: pattern)
        promptLines = scan?.promptLines(in: lines) ?? []
    }

    /// The line at the top of what's on screen.
    private func topVisibleLine() -> Int {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              !lineStarts.isEmpty else { return 0 }
        let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let offset = layout.characterIndexForGlyph(at: glyphs.location)
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func jumpToPrompt(previous: Bool) {
        guard let textView, !promptLines.isEmpty else { return }
        let top = topVisibleLine()
        guard let line = previous ? promptLines.last(where: { $0 < top }) : promptLines.first(where: { $0 > top })
        else { return }
        let range = NSRange(location: lineStarts[line], length: max(1, lines[line].utf16.count))
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                       in: container)
        textView.scroll(NSPoint(x: 0, y: rect.minY))
        textView.showFindIndicator(for: range)
    }

    func lastOutput() -> String? {
        guard let range = scan?.lastOutput(in: lines, width: paneWidth) else { return nil }
        return lines[range].joined(separator: "\n")
    }
}

private struct MacHistoryText: NSViewRepresentable {
    let text: String
    let paneWidth: Int?
    let promptPattern: String
    let controller: MacHistoryController

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isAutomaticLinkDetectionEnabled = false
        controller.textView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        guard coordinator.shownText != text || coordinator.shownPattern != promptPattern else { return }
        let textChanged = coordinator.shownText != text
        coordinator.shownText = text
        coordinator.shownPattern = promptPattern
        if textChanged { view.string = text }
        let (text, pattern, width, controller) = (text, promptPattern, paneWidth, controller)
        DispatchQueue.main.async {
            controller.index(text, pattern: pattern, paneWidth: width)
            // Open on the newest output, like the terminal it came from.
            if textChanged { view.scrollToEndOfDocument(nil) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var shownText: String?
        var shownPattern: String?
    }
}
