import XCTest
@testable import BsnsSSHCore

final class WorkspaceTests: XCTestCase {
    private let f = TmuxCommand.fieldSeparator

    func testOldWorkspaceDecodesWithoutLayout() throws {
        let json = "{\"id\":\"E612E670-3FE1-487F-8127-C702929FA89E\",\"name\":\"Site\",\"path\":\"~/site\",\"hosts\":[]}"
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        XCTAssertNil(workspace.windows)
        XCTAssertNil(WorkspaceCommand.prepare(workspace))
        XCTAssertEqual(workspace.tmuxSession, "Site")
    }

    func testLayoutResolvesHostPathAndContainsOnlyEncodedData() throws {
        let w = Workspace(name: "Development", path: "~/workspace", pathOverrides: ["laptop": "~/code"],
                          sessionName: "0", windows: [WorkspaceWindow(index: 0, name: "review", tool: "review")])
        XCTAssertEqual(w.tmuxSession, "0")
        let command = try XCTUnwrap(WorkspaceCommand.prepare(w, host: "laptop"))
        XCTAssertEqual(command.filter { $0 == "'" }.count, 2)
        let encoded = try XCTUnwrap(command.components(separatedBy: " apply ").last).dropLast()
        let data = try XCTUnwrap(Data(base64Encoded: String(encoded)))
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded.path, "~/code")
        XCTAssertEqual(decoded.windows, w.windows)
        XCTAssertNil(decoded.pathOverrides)
    }

    func testInvalidAndDuplicateWindowsAreRefused() {
        var w = Workspace(name: "work", path: "~/workspace", windows: [WorkspaceWindow(index: 0, name: "$(bad)")])
        XCTAssertNil(WorkspaceCommand.prepare(w))
        w.windows = [WorkspaceWindow(index: 0, name: "a"), WorkspaceWindow(index: 0, name: "b")]
        XCTAssertNil(WorkspaceCommand.prepare(w))
    }

    func testSessionNameAndPerHostPaths() {
        let workspace = Workspace(name: "Site Rebuild!", path: "/Users/me/work/site",
                                  pathOverrides: ["laptop.local": "~/work/site"], hosts: ["Studio", "laptop.local"])
        XCTAssertEqual(workspace.tmuxSession, "Site-Rebuild")
        XCTAssertEqual(workspace.path(on: "LAPTOP.local"), "~/work/site")
        XCTAssertEqual(workspace.path(on: "studio"), "/Users/me/work/site")
        XCTAssertTrue(workspace.includes(host: "studio"))
        XCTAssertFalse(workspace.includes(host: "other"))
    }

    func testPathsAreQuotedOrRefused() {
        XCTAssertEqual(WorkspaceCommand.quoted("/Volumes/Dev/my project"), "\"/Volumes/Dev/my project\"")
        XCTAssertEqual(WorkspaceCommand.quoted("~/work/site"), "\"$HOME/work/site\"")
        XCTAssertEqual(WorkspaceCommand.quoted("~"), "\"$HOME\"")
        for bad in ["relative/path", "/a/$(rm -rf x)", "/a/`x`", "/a/\"b", "/a/'b", "/a\\b", "", "/a\nb"] {
            XCTAssertNil(WorkspaceCommand.quoted(bad), bad)
        }
    }

    func testStatusCommandIsOneQuotedScriptAndReadOnly() throws {
        let command = try XCTUnwrap(WorkspaceCommand.status(path: "~/work/site", statusCommand: "bsns-wip-mirror status"))
        XCTAssertEqual(command.filter { $0 == "'" }.count, 2)
        XCTAssertTrue(command.contains("cd \"$HOME/work/site\""))
        XCTAssertTrue(command.contains("bsns-wip-mirror status"))
        XCTAssertNil(WorkspaceCommand.status(path: "/a/$x", statusCommand: nil))
        // A status command that can't sit in the script is dropped, not run.
        let dropped = try XCTUnwrap(WorkspaceCommand.status(path: "/a", statusCommand: "echo 'x'"))
        XCTAssertFalse(dropped.contains("| head -"))
        XCTAssertEqual(dropped.filter { $0 == "'" }.count, 2)
    }

    func testParsesStatus() throws {
        let output = "banner\nws\(f)here\nws\(f)branch\(f)main\nws\(f)dirty\(f)3\nws\(f)ahead\(f)2\nws\(f)status\(f)studio: 2m ago\nws\(f)status\(f)laptop: 40s ago\n"
        let status = try XCTUnwrap(WorkspaceCommand.parseStatus(output))
        XCTAssertTrue(status.exists)
        XCTAssertEqual(status.summary, "main · 3 changed · 2 unpushed")
        XCTAssertEqual(status.statusLines, ["studio: 2m ago", "laptop: 40s ago"])
        XCTAssertEqual(WorkspaceCommand.parseStatus("ws\(f)missing\n")?.summary, "not on this machine")
        XCTAssertEqual(WorkspaceCommand.parseStatus("ws\(f)here\nws\(f)branch\(f)main\nws\(f)dirty\(f)0\n")?.summary, "main · clean")
        XCTAssertNil(WorkspaceCommand.parseStatus("Connection closed\n"))
    }

    func testLeastBusyUsesLoadPerCore() {
        XCTAssertEqual(WorkspaceCommand.leastBusy([(id: "studio", load: 52, cpus: 32), (id: "laptop", load: 6, cpus: 18)]), "laptop")
        XCTAssertEqual(WorkspaceCommand.leastBusy([(id: "studio", load: 4, cpus: 32), (id: "laptop", load: 6, cpus: 18)]), "studio")
        XCTAssertEqual(WorkspaceCommand.leastBusy([(id: "a", load: nil, cpus: nil), (id: "b", load: 9, cpus: 8)]), "b")
        XCTAssertEqual(WorkspaceCommand.leastBusy([(id: "a", load: nil, cpus: nil)]), "a")
    }

    func testAttachCommandStartsInTheProjectDirectoryWhenItIsSafe() {
        XCTAssertEqual(MoshServerCommand.attachCommand("site", directory: "~/work/site"),
                       "tmux new-session -A -s site -c \"$HOME/work/site\"")
        XCTAssertEqual(MoshServerCommand.attachCommand("site", directory: "/a/$(x)"), "tmux new-session -A -s site")
        let suffix = MoshServerCommand.tmuxSuffix("site", clipboard: true, directory: "/Volumes/Dev/site")
        XCTAssertTrue(suffix.contains("new-session -A -s site -c \"/Volumes/Dev/site\""))
        XCTAssertEqual(suffix.filter { $0 == "'" }.count, 2)
    }

    func testAWindowsToolIsALabelNotACommand() throws {
        XCTAssertTrue(WorkspaceWindow(index: 1, name: "edit", tool: "editor").isValid)
        XCTAssertTrue(WorkspaceWindow(index: 1, name: "edit").isValid)
        for bad in ["", "rm -rf /", "a;b", "$(x)", String(repeating: "x", count: 33)] {
            XCTAssertFalse(WorkspaceWindow(index: 1, name: "edit", tool: bad).isValid, bad)
        }
        // Saved under the field's earlier name: still read, written back as `tool`.
        let id = UUID()
        let legacy = Data("{\"id\":\"\(id.uuidString)\",\"index\":2,\"name\":\"review\",\"agent\":\"review\"}".utf8)
        let window = try JSONDecoder().decode(WorkspaceWindow.self, from: legacy)
        XCTAssertEqual(window.tool, "review")
        let written = String(decoding: try JSONEncoder().encode(window), as: UTF8.self)
        XCTAssertTrue(written.contains("\"tool\":\"review\""))
        XCTAssertFalse(written.contains("agent"))
    }
}

final class DeepLinkTests: XCTestCase {
    func testSessionAndWorkspaceLinksRoundTrip() throws {
        let session = DeepLink.session(host: "studio", user: "dev", tmux: "main")
        XCTAssertEqual(DeepLink(try XCTUnwrap(session.url)), session)
        let workspace = DeepLink.workspace(name: "Site Rebuild", host: "laptop.local")
        XCTAssertEqual(DeepLink(try XCTUnwrap(workspace.url)), workspace)
    }

    func testParsing() {
        XCTAssertEqual(DeepLink(URL(string: "bsns-ssh://open?host=studio")!), .session(host: "studio", user: nil, tmux: nil))
        // A tmux name is reduced to what can be passed to a shell.
        XCTAssertEqual(DeepLink(URL(string: "bsns-ssh://open?host=studio&tmux=a%3Brm%20-rf")!),
                       .session(host: "studio", user: nil, tmux: "arm-rf"))
        XCTAssertNil(DeepLink(URL(string: "bsns-ssh://open")!))
        XCTAssertNil(DeepLink(URL(string: "bsns-ssh://delete?host=studio")!))
        XCTAssertNil(DeepLink(URL(string: "https://open?host=studio")!))
    }
}
