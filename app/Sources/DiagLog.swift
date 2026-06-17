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

    /// Record an event. Safe to call from any thread/actor: it writes the unified
    /// log inline (nonisolated) and hops to the main actor to append to the buffer.
    nonisolated static func log(_ category: String, _ message: String) {
        logger.notice("[\(category, privacy: .public)] \(message, privacy: .public)")
        Task { @MainActor in shared.append(category, message) }
    }

    private func append(_ category: String, _ message: String) {
        entries.append(Entry(time: Date(), category: category, message: message))
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
    }

    func clear() { entries.removeAll() }

    /// The whole log as copyable plain text (oldest → newest).
    var plainText: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return entries.map { "\(f.string(from: $0.time))  [\($0.category)] \($0.message)" }.joined(separator: "\n")
    }
}

/// Settings → Diagnostics: the live in-app log with copy/share + clear.
struct DiagnosticsView: View {
    @State private var log = DiagLog.shared
    @State private var copied = false

    var body: some View {
        List {
            if log.entries.isEmpty {
                Text("No events yet. Reproduce an issue (e.g. connect via mosh, then background and return) and the log will fill here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
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
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = log.plainText
                    copied = true
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                ShareLink(item: log.plainText) { Image(systemName: "square.and.arrow.up") }
                Button(role: .destructive) { log.clear(); copied = false } label: { Image(systemName: "trash") }
            }
        }
    }
}
