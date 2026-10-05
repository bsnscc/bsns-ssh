import SwiftUI
import BsnsSSHCore

/// Questions waiting for an answer, and what was said recently.
struct MacInboxView: View {
    @State private var center = AskCenter.shared

    var body: some View {
        List {
            Section("Waiting for You") {
                if center.pending.isEmpty {
                    Text("Nothing is waiting.").foregroundStyle(.secondary)
                }
                ForEach(center.pending) { ask in
                    VStack(alignment: .leading, spacing: 8) {
                        AskHeader(ask: ask)
                        Text(ask.text).textSelection(.enabled)
                        HStack {
                            ForEach(ask.options, id: \.self) { option in
                                Button(option) { center.answer(AskAnswer(askID: ask.id, choice: option)) }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if !center.history.isEmpty {
                Section("Recent") {
                    ForEach(center.history) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            AskHeader(ask: entry.ask)
                            Text(entry.ask.text).foregroundStyle(.secondary)
                            if let answer = entry.answer {
                                Text("You answered: \(answer)").font(.caption).foregroundStyle(Brand.accent)
                            }
                        }
                    }
                }
            }
            Section {
                Text("Anything on this Mac can ask: `bsns ask \"Deploy to prod?\" --option approve --option rollback` waits here for your answer and prints it; `bsns notify \"Build finished\"` just tells you. The `bsns` command is inside the app — link it onto your PATH with:\n`ln -sf \(AskCLI.path) /usr/local/bin/bsns`")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .navigationTitle("Inbox")
    }
}

private struct AskHeader: View {
    let ask: Ask
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ask.isQuestion ? "questionmark.bubble" : "bell").foregroundStyle(Brand.accent)
            Text(ask.source.map { "\($0) · \(ask.machine)" } ?? ask.machine).font(.caption.weight(.medium))
            Text(ask.created.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
        }
    }
}

enum AskCLI {
    /// Where the command-line tool sits inside the app.
    static var path: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bsns").path
    }
}
