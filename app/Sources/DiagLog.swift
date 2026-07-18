import Foundation
import os
import SwiftUI

/// A small in-app diagnostic log — a ring buffer of recent events, viewable in
/// Settings → Diagnostics (no Console.app/cable needed) and mirrored to the
/// unified log at `.notice` (subsystem `cc.bsns.ssh`) so it's visible by default.
/// Used to debug the mosh resume/size path on-device.
@Observable
@MainActor
final class DiagLog {
    static let shared = DiagLog()

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let category: String
        let message: String
    }

    private(set) var entries: [Entry] = []
    private let cap = 600
    nonisolated private static let logger = Logger(subsystem: "cc.bsns.ssh", category: "diag")
    nonisolated private static let fileQueue = DispatchQueue(label: "cc.bsns.ssh.diagfile")
    nonisolated private static let persistentCapBytes = 256 * 1024

    /// Master gate. Recording is OFF by default: a live session (e.g. a mosh tmux
    /// with an updating pane) emits several events per frame, and each `log` call
    /// does a synchronous file write + unified-log write + a main-actor hop — dozens
    /// of synchronous disk writes a second, which needlessly drains the battery in
    /// normal use. Enable it from Settings → Diagnostics only while reproducing an
    /// issue. Read lock-free from every I/O thread; a stale value costs at most one
    /// logged (or dropped) line, which is harmless.
    nonisolated(unsafe) static var enabled = false

    /// Re-read the persisted toggle into the cached flag. Called at launch and when
    /// the Diagnostics toggle changes.
    nonisolated static func refreshEnabled() {
        enabled = UserDefaults.standard.bool(forKey: SettingsKey.diagnosticsEnabled)
    }

    /// Record an event. A no-op unless recording is `enabled`. Safe to call from any
    /// thread/actor: it writes the unified log + persistent file inline (nonisolated)
    /// and hops to the main actor to append to the live buffer.
    /// INVARIANT: never pass secrets here (keys, PINs, passphrases, tokens) — the
    /// message is mirrored to the unified log at `.public`, so it's readable via
    /// Console.app / sysdiagnose. Log only timing, sizes, and state.
    nonisolated static func log(_ category: String, _ message: String) {
        guard enabled else { return }
        logger.notice("[\(category, privacy: .public)] \(message, privacy: .public)")
        appendPersistent(category, message)
        Task { @MainActor in shared.append(category, message) }
    }

    nonisolated static func markLaunch() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log("app", "launch version=\(version) build=\(build) pid=\(getpid()) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    private func append(_ category: String, _ message: String) {
        entries.append(Entry(time: Date(), category: category, message: message))
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
    }

    func clear() {
        entries.removeAll()
        Self.clearPersistent()
    }

    nonisolated static func persistentPlainText() -> String {
        guard let url = persistentURL() else { return "" }
        return fileQueue.sync {
            guard let data = try? Data(contentsOf: url) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    nonisolated private static func appendPersistent(_ category: String, _ message: String) {
        guard let url = persistentURL() else { return }
        fileQueue.sync {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: url.path) == false {
                    fm.createFile(atPath: url.path, contents: nil)
                }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let line = "\(formatter.string(from: Date()))  [\(category)] \(message)\n"
                guard let data = line.data(using: .utf8),
                      let handle = try? FileHandle(forWritingTo: url) else { return }
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
                trimPersistentLogIfNeeded(url, fileManager: fm)
            } catch {
                // Diagnostics must never affect app behavior.
            }
        }
    }

    nonisolated private static func clearPersistent() {
        guard let url = persistentURL() else { return }
        fileQueue.sync {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated private static func persistentURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("events.log")
    }

    nonisolated private static func trimPersistentLogIfNeeded(_ url: URL, fileManager fm: FileManager) {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > persistentCapBytes * 2,
              let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(persistentCapBytes)
        try? Data(tail).write(to: url, options: .atomic)
    }

    /// The whole log as copyable plain text (oldest → newest).
    var plainText: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return entries.map { "\(f.string(from: $0.time))  [\($0.category)] \($0.message)" }.joined(separator: "\n")
    }
}

/// Settings → Diagnostics: the live in-app log with copy/share + clear.
struct DiagnosticsView: View {
    @State private var log = DiagLog.shared
    @State private var savedLog = ""
    @State private var copied = false
    @AppStorage(SettingsKey.diagnosticsEnabled) private var recording = false

    private var savedLines: [String] {
        savedLog.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(250)
            .reversed()
            .map(String.init)
    }

    private var diagnosticsText: String {
        savedLog.isEmpty ? log.plainText : savedLog
    }

    var body: some View {
        List {
            Section {
                Toggle("Record events", isOn: $recording)
                    .onChange(of: recording) { _, _ in DiagLog.refreshEnabled() }
            } footer: {
                Text("Off by default to save battery — recording writes several events per frame to disk. Turn it on, reproduce the issue, then copy the log below.")
            }
            if recording && savedLines.isEmpty && log.entries.isEmpty {
                Text("Recording… reproduce an issue (e.g. connect via mosh, then background and return) and the log will fill here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if savedLines.isEmpty == false {
                Section("Saved event log") {
                    ForEach(Array(savedLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } else {
                // Newest first.
                ForEach(log.entries.reversed()) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.message).font(.system(.footnote, design: .monospaced))
                        Text("\(e.category) · \(e.time, format: .dateTime.hour().minute().second())")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reloadSavedLog() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    reloadSavedLog()
                    UIPasteboard.general.string = diagnosticsText
                    copied = true
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                ShareLink(item: diagnosticsText) { Image(systemName: "square.and.arrow.up") }
                Button { reloadSavedLog() } label: { Image(systemName: "arrow.clockwise") }
                Button(role: .destructive) {
                    log.clear()
                    savedLog = ""
                    copied = false
                } label: { Image(systemName: "trash") }
            }
        }
    }

    private func reloadSavedLog() {
        savedLog = DiagLog.persistentPlainText()
    }
}
