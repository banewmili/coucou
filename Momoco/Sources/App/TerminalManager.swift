import SwiftUI
import Foundation
import AppKit

/// Persistent login shell (zsh) that powers the in-app Terminal.
/// Commands run through pipes (no TTY): install tools with brew/npm/npx,
/// then connect them to Momoco via MCP Servers or Connected Apps.
/// Interactive full-screen TUIs (vim, htop) and sudo password prompts
/// are not supported in this embedded shell.
///
/// Marked @unchecked Sendable like MCPConnection: all @Published state is
/// mutated on the main thread (pipe reads hop via DispatchQueue.main).
final class TerminalManager: ObservableObject, @unchecked Sendable {
    static let shared = TerminalManager()

    @Published private(set) var lines: [String] = []

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var pending = ""

    init() {
        start()
    }

    func start() {
        stop()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l"]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.appendOutput(text) }
        }
        do {
            try proc.run()
            process = proc
            stdinPipe = inPipe
            stdoutPipe = outPipe
            appendOutput("momoco shell ready. Type a command and press Enter.\n")
        } catch {
            appendOutput("Could not start shell: \(error.localizedDescription)\n")
        }
    }

    func run(_ command: String) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        if process?.isRunning != true { start() }
        appendOutput("$ " + cmd + "\n")
        if let data = (cmd + "\n").data(using: .utf8) {
            try? stdinPipe?.fileHandleForWriting.write(contentsOf: data)
        }
    }

    func clear() {
        lines = []
        pending = ""
    }

    func restart() {
        start()
    }

    private func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
    }

    private func appendOutput(_ text: String) {
        pending += TerminalManager.stripANSI(text)
        var parts = pending.components(separatedBy: "\n")
        pending = parts.removeLast()
        lines.append(contentsOf: parts)
        if lines.count > 2000 {
            lines.removeFirst(lines.count - 2000)
        }
    }

    /// Strip ANSI escape sequences so piped output renders as plain text.
    static func stripANSI(_ s: String) -> String {
        let pattern = "\u{1B}\\[[0-9;?]*[A-Za-z]|\u{1B}\\][^\u{07}]*\u{07}|\u{1B}[()][0-9A-B]|\r"
        return s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}

// MARK: - Terminal view (embedded in Settings)

struct TerminalView: View {
    @ObservedObject private var term = TerminalManager.shared
    @State private var command: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run install commands here (brew, npm, npx...), then connect the tool to Momoco via MCP Servers above.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(term.lines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("termEnd")
                        .padding(8)
                }
                .frame(height: 220)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .onChange(of: term.lines.count) { _ in
                    proxy.scrollTo("termEnd", anchor: .bottom)
                }
            }

            HStack {
                Text("$")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                TextField("command, e.g. brew install node", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { submit() }
                Button("Run") { submit() }
                    .buttonStyle(.borderedProminent)
            }

            HStack {
                Button("Clear") { term.clear() }
                    .buttonStyle(.bordered)
                Button("Restart shell") { term.restart() }
                    .buttonStyle(.bordered)
                Spacer()
                Text("no sudo / fullscreen apps")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(6)
    }

    private func submit() {
        term.run(command)
        command = ""
    }
}

// MARK: - Connected app row

struct ConnectedAppRow: View {
    let name: String
    let detail: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(connected ? "Connected" : "Not connected")
                .font(.system(size: 11))
                .foregroundColor(connected ? .green : .secondary)
        }
    }
}
