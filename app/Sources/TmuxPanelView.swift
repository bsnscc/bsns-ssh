import SwiftUI
import UIKit
import BsnsSSHCore

/// tmux, beside the terminal rather than through it: the session's windows, and
/// the active pane's full history as native text.
///
/// Both come over a second SSH connection opened for the panel. That matters
/// most over mosh, which carries only the screen as it changes — the history
/// tmux keeps is the complete record, and here it can be scrolled, searched and
/// selected like any other text instead of being driven through copy mode.
struct TmuxPanelView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case windows, history
        var id: String { rawValue }
        var label: String { self == .windows ? "Windows" : "History" }
    }

    @State private var tab: Tab
    @State private var model: TmuxPanelModel
    @State private var text = HistoryTextController()
    @State private var notice: String?
    @AppStorage(SettingsKey.promptPattern) private var promptPattern = PromptScan.defaultPattern
    @Environment(\.dismiss) private var dismiss

    init(session: TerminalSession, tab: Tab) {
        _tab = State(initialValue: tab)
        _model = State(initialValue: TmuxPanelModel(session: session))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14).padding(.vertical, 8)

                switch model.state {
                case .connecting:
                    Spacer()
                    ProgressView("Connecting…")
                    Spacer()
                case .failed(let message):
                    failure(message)
                case .ready:
                    if tab == .windows { windowList } else { history }
                }
            }
            .navigationTitle("tmux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) { actions }
            }
            .overlay(alignment: .bottom) { noticeBanner }
        }
        .task {
            await model.connect()
            await load(tab)
        }
        .onChange(of: tab) { _, newTab in Task { await load(newTab) } }
        .onDisappear { model.close() }
    }

    private func load(_ tab: Tab) async {
        switch tab {
        case .windows: await model.loadWindows()
        case .history: if model.history == nil { await model.loadHistory(lines: TmuxPanelModel.defaultHistoryLines) }
        }
    }

    @ViewBuilder private var actions: some View {
        if case .ready = model.state {
            switch tab {
            case .windows:
                Button { Task { if await model.newWindow() { dismiss() } } } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New window")
                Button { Task { await model.loadWindows() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh")
            case .history:
                Button { text.jumpToPrompt(previous: true) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Previous prompt")
                    .disabled(!text.hasPrompts)
                Button { text.jumpToPrompt(previous: false) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Next prompt")
                    .disabled(!text.hasPrompts)
                Menu {
                    Button { text.find() } label: { Label("Find…", systemImage: "magnifyingglass") }
                    Button { copyLastOutput() } label: { Label("Copy Last Output", systemImage: "doc.on.doc") }
                        .disabled(!text.hasPrompts)
                    Button { copyAll() } label: { Label("Copy All", systemImage: "doc.on.clipboard") }
                    Divider()
                    Button { Task { await model.loadHistory(lines: TmuxPanelModel.defaultHistoryLines) } } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    Button { Task { await model.loadHistory(lines: TmuxCommand.maxHistoryLines) } } label: {
                        Label("Load Everything", systemImage: "arrow.down.to.line")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel("More")
                }
            }
        }
    }

    private var windowList: some View {
        List {
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if model.windows.isEmpty, model.error == nil, !model.busy {
                Text("No windows found.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.windows) { window in
                Button {
                    Task { if await model.select(window) { dismiss() } }
                } label: {
                    HStack(spacing: 12) {
                        Text("\(window.index)")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(minWidth: 22, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.name.isEmpty ? window.command : window.name)
                                .font(.body.monospaced()).foregroundStyle(.primary)
                            if !window.name.isEmpty, window.command != window.name {
                                Text(window.command).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if window.isActive {
                            Image(systemName: "checkmark").foregroundStyle(Brand.accent)
                                .accessibilityLabel("Current window")
                        }
                    }
                }
            }
        }
        .overlay { if model.busy && model.windows.isEmpty { ProgressView() } }
    }

    @ViewBuilder private var history: some View {
        if let error = model.error, model.history == nil {
            failure(error)
        } else if let history = model.history {
            HistoryTextView(text: history, paneWidth: model.historyWidth, promptPattern: promptPattern, controller: text)
                .overlay { if model.busy { ProgressView().padding().background(.bar, in: Capsule()) } }
        } else {
            Spacer()
            ProgressView("Reading history…")
            Spacer()
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
            Text(message).font(.callout).multilineTextAlignment(.center).padding(.horizontal, 28)
            Button("Try Again") { Task { await model.connect(); await load(tab) } }
                .buttonStyle(.bordered)
            Spacer()
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice {
            Text(notice).font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.bar, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .padding(.bottom, 18)
                .transition(.opacity)
        }
    }

    private func flash(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if notice == message { notice = nil }
        }
    }

    private func copyLastOutput() {
        guard let output = text.lastOutput() else {
            flash("No command output found")
            return
        }
        UIPasteboard.general.string = output
        let lines = output.split(whereSeparator: \.isNewline).count
        flash("Copied \(lines) line\(lines == 1 ? "" : "s")")
    }

    private func copyAll() {
        guard let history = model.history else { return }
        UIPasteboard.general.string = history
        flash("Copied everything")
    }
}

/// Runs the panel's tmux commands over one side connection.
@MainActor
@Observable
final class TmuxPanelModel {
    enum State { case connecting, ready, failed(String) }

    static let defaultHistoryLines = 10_000

    private(set) var state = State.connecting
    private(set) var windows: [TmuxCommand.Window] = []
    private(set) var history: String?
    /// Columns of the pane the history came from, for telling a wrapped command
    /// from output.
    private(set) var historyWidth: Int?
    private(set) var error: String?
    private(set) var busy = false

    @ObservationIgnored private let session: TerminalSession
    @ObservationIgnored private var channel: SSHExecSession?

    init(session: TerminalSession) { self.session = session }

    func connect() async {
        channel?.close()
        channel = nil
        state = .connecting
        do {
            channel = try await session.openSideChannel()
            state = .ready
        } catch {
            state = .failed(TerminalSession.describe(error))
        }
    }

    func close() {
        channel?.close()
        channel = nil
    }

    /// Run one tmux command; nil (with `error` set) if it failed.
    private func run(_ command: String, streamCap: Int = SSHShell.execStreamCap) async -> String? {
        guard let channel else { return nil }
        busy = true
        defer { busy = false }
        do {
            let result = try await channel.run(command, streamCap: streamCap)
            guard result.exitStatus == 0 else {
                error = Self.explain(result)
                return nil
            }
            error = nil
            return result.stdoutString
        } catch {
            // The connection dropped under the panel — say so, and let "Try
            // Again" reconnect, rather than failing every command after it.
            state = .failed(TerminalSession.describe(error))
            return nil
        }
    }

    private static func explain(_ result: SSHShell.ExecResult) -> String {
        if result.exitStatus == 127 { return "tmux isn't installed on the server, or isn't on its PATH." }
        let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("no server running") || detail.contains("no tmux client") || detail.contains("error connecting") {
            return "No tmux session is attached to this terminal."
        }
        return detail.isEmpty ? "tmux exited with status \(result.exitStatus)." : String(detail.prefix(240))
    }

    func loadWindows() async {
        guard let output = await run(TmuxCommand.listWindows(session.tmuxTarget)) else { return }
        windows = TmuxCommand.parseWindows(output)
    }

    func select(_ window: TmuxCommand.Window) async -> Bool {
        await run(TmuxCommand.selectWindow(session.tmuxTarget, index: window.index)) != nil
    }

    func newWindow() async -> Bool {
        await run(TmuxCommand.newWindow(session.tmuxTarget)) != nil
    }

    func loadHistory(lines: Int) async {
        guard let output = await run(TmuxCommand.captureHistory(session.tmuxTarget, lines: lines),
                                     streamCap: SSHExecSession.historyStreamCap) else { return }
        // The capture includes the visible screen, which is blank below the
        // cursor; drop that tail so the view ends on the last real line.
        let (width, text) = TmuxCommand.parseHistory(output)
        historyWidth = width
        var rows = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        while let last = rows.last, last.allSatisfy(\.isWhitespace) { rows.removeLast() }
        history = rows.joined(separator: "\n")
    }
}

/// Lets the panel's toolbar drive the text view: find, prompt jumps, copy.
@MainActor
@Observable
final class HistoryTextController {
    @ObservationIgnored fileprivate weak var textView: UITextView?
    /// UTF-16 offset of each line start, and which lines look like prompts.
    @ObservationIgnored fileprivate var lineStarts: [Int] = []
    @ObservationIgnored fileprivate var lines: [Substring] = []
    @ObservationIgnored fileprivate var scan: PromptScan?
    @ObservationIgnored fileprivate var paneWidth: Int?
    @ObservationIgnored private var highlighted: NSRange?
    fileprivate(set) var promptLines: [Int] = []

    var hasPrompts: Bool { !promptLines.isEmpty }

    func find() {
        guard let textView else { return }
        textView.becomeFirstResponder()
        textView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

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
        highlighted = nil
    }

    private func range(ofLine line: Int) -> NSRange {
        NSRange(location: lineStarts[line], length: lines[line].utf16.count)
    }

    /// The line at the top of what's on screen.
    private func topVisibleLine() -> Int {
        guard let textView else { return 0 }
        let point = CGPoint(x: textView.textContainerInset.left + 1,
                            y: textView.contentOffset.y + textView.textContainerInset.top + 1)
        guard let position = textView.closestPosition(to: point) else { return 0 }
        let offset = textView.offset(from: textView.beginningOfDocument, to: position)
        // Last line whose start is at or before the offset.
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
        let target = previous ? promptLines.last(where: { $0 < top }) : promptLines.first(where: { $0 > top })
        guard let line = target else { return }
        let range = range(ofLine: line)
        guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: max(range.length, 1)),
              let textRange = textView.textRange(from: start, to: end) else { return }
        // Put the prompt at the top edge, as far as the content allows.
        let rect = textView.firstRect(for: textRange)
        let maxY = max(0, textView.contentSize.height - textView.bounds.height)
        textView.setContentOffset(CGPoint(x: 0, y: min(max(0, rect.minY - textView.textContainerInset.top), maxY)),
                                  animated: false)
        highlight(range)
    }

    private func highlight(_ range: NSRange) {
        guard let storage = textView?.textStorage else { return }
        if let old = highlighted, NSMaxRange(old) <= storage.length {
            storage.removeAttribute(.backgroundColor, range: old)
        }
        guard NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.35), range: range)
        highlighted = range
    }

    /// The output of the most recent command that printed something.
    func lastOutput() -> String? {
        guard let range = scan?.lastOutput(in: lines, width: paneWidth) else { return nil }
        return lines[range].joined(separator: "\n")
    }
}

/// The history as a native text view: scrolls with momentum, selects and copies
/// like any text, and has the system's find bar.
private struct HistoryTextView: UIViewRepresentable {
    let text: String
    let paneWidth: Int?
    let promptPattern: String
    let controller: HistoryTextController

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isFindInteractionEnabled = true
        view.alwaysBounceVertical = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.autocorrectionType = .no
        view.dataDetectorTypes = []
        controller.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.shownText != text || coordinator.shownPattern != promptPattern else { return }
        let textChanged = coordinator.shownText != text
        coordinator.shownText = text
        coordinator.shownPattern = promptPattern
        if textChanged { view.text = text }
        let (text, pattern, width, controller) = (text, promptPattern, paneWidth, controller)
        // Deferred: indexing publishes the prompt list, and this runs inside a
        // view update.
        DispatchQueue.main.async {
            controller.index(text, pattern: pattern, paneWidth: width)
            guard textChanged else { return }
            // Open on the newest output, like the terminal it came from.
            view.layoutIfNeeded()
            let bottom = max(0, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
            view.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shownText: String?
        var shownPattern: String?
    }
}
