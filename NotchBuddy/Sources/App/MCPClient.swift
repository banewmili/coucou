import Foundation

// MARK: - MCP errors

enum MCPError: LocalizedError {
    case notRunning(String)
    case spawnFailed(String)
    case timeout(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .notRunning(let n):    return "MCP server '\(n)' is not running."
        case .spawnFailed(let m):   return "Could not start MCP server: \(m)"
        case .timeout(let m):       return "MCP request timed out: \(m)"
        case .protocolError(let m): return "MCP protocol error: \(m)"
        }
    }
}

// MARK: - Tool definition (provider-agnostic)

struct MCPToolDefinition {
    let serverName: String
    let name: String
    let description: String
    /// JSON Schema dictionary for the tool input.
    let inputSchema: [String: Any]
}

/// Type-erased JSON value that can cross actor boundaries (Swift 6).
/// The payload always comes from JSONSerialization, i.e. value types only
/// (String/Int/Double/Bool/Array/Dictionary), so sharing it is safe.
struct SendableJSON: @unchecked Sendable {
    let value: Any
}

// MARK: - JSON-RPC 2.0 connection over stdio

/// Speaks newline-delimited JSON-RPC 2.0 with an MCP server process.
/// All mutable state is guarded by a lock; safe to use from any thread.
final class MCPConnection: @unchecked Sendable {
    var name: String = ""

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let lock = NSLock()
    private var nextId: Int = 1
    private var pending: [Int: CheckedContinuation<SendableJSON, Error>] = [:]
    private var readBuffer = Data()
    private var started = false

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return started && process.isRunning
    }

    /// Starts the server. `command` may be a bare binary name; common install
    /// locations (Homebrew, ~/.local/bin) are added to PATH for GUI launches.
    func start(command: String, args: [String], env: [String: String]) throws {
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin",
                          "\(NSHomeDirectory())/.local/bin"]
        var fullEnv = ProcessInfo.processInfo.environment
        let path = ([fullEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"] + extraPaths)
            .joined(separator: ":")
        fullEnv["PATH"] = path
        for (k, v) in env { fullEnv[k] = v }

        let cmdLine = ([command] + args).map(Self.shellEscape).joined(separator: " ")
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec \(cmdLine)"]
        process.environment = fullEnv
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let readHandle = stdoutPipe.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }  // EOF; process ended
            self?.didReceiveData(data)
        }
        // Drain stderr so a chatty server can never block on a full pipe.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
        } catch {
            throw MCPError.spawnFailed(error.localizedDescription)
        }
        lock.lock()
        started = true
        lock.unlock()
    }

    func stop() {
        let stale: [CheckedContinuation<SendableJSON, Error>] = lock.withLock {
            started = false
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        for cont in stale {
            cont.resume(throwing: MCPError.notRunning(name))
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    // MARK: MCP handshake

    func initialize() async throws {
        let params: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Coucou", "version": "0.1.0"],
        ]
        _ = try await sendRequest(method: "initialize", params: params)
        try sendNotification(method: "notifications/initialized", params: [:])
    }

    func listTools() async throws -> [SendableJSON] {
        let result = try await sendRequest(method: "tools/list", params: [:])
        guard let dict = result.value as? [String: Any],
              let tools = dict["tools"] as? [[String: Any]] else {
            return []
        }
        return tools.map { SendableJSON(value: $0) }
    }

    /// Calls a tool; returns the concatenated text content of the result.
    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let result = try await sendRequest(method: "tools/call",
                                           params: ["name": name, "arguments": arguments])
        guard let dict = result.value as? [String: Any] else { return "" }
        var parts: [String] = []
        if let content = dict["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "text",
                   let t = block["text"] as? String {
                    parts.append(t)
                }
            }
        }
        let text = parts.joined(separator: "\n")
        if (dict["isError"] as? Bool) == true {
            throw MCPError.protocolError(text.isEmpty ? "tool reported an error" : text)
        }
        return text
    }

    // MARK: JSON-RPC plumbing

    private func sendRequest(method: String, params: [String: Any],
                             timeout: TimeInterval = 120) async throws -> SendableJSON {
        // NSLock.lock()/unlock() are unavailable in async contexts (Swift 6);
        // withLock is the sanctioned scoped alternative.
        let id: Int = lock.withLock {
            let id = nextId
            nextId += 1
            return id
        }
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { message["params"] = params }
        let line = try JSONSerialization.data(withJSONObject: message)

        return try await withThrowingTaskGroup(of: SendableJSON.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SendableJSON, Error>) in
                    lock.withLock { self.pending[id] = cont }
                    do {
                        var framed = line
                        framed.append(0x0A)
                        try self.stdinPipe.fileHandleForWriting.write(contentsOf: framed)
                    } catch {
                        lock.withLock { self.pending.removeValue(forKey: id) }
                        cont.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MCPError.timeout(method)
            }
            guard let result = try await group.next() else {
                throw MCPError.timeout(method)
            }
            group.cancelAll()
            return result
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !params.isEmpty { message["params"] = params }
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: line)
    }

    private func didReceiveData(_ data: Data) {
        var lines: [Data] = []
        lock.lock()
        readBuffer.append(data)
        while let range = readBuffer.range(of: Data([0x0A])) {
            lines.append(readBuffer.subdata(in: readBuffer.startIndex..<range.lowerBound))
            readBuffer.removeSubrange(readBuffer.startIndex..<range.upperBound)
        }
        lock.unlock()
        for line in lines { didReceiveLine(line) }
    }

    private func didReceiveLine(_ line: Data) {
        guard !line.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }
        // Responses carry our Int id; notifications/results without id are ignored.
        var idValue: Int?
        if let id = json["id"] as? Int { idValue = id }
        else if let idNum = json["id"] as? NSNumber { idValue = idNum.intValue }
        guard let id = idValue else { return }

        let cont: CheckedContinuation<SendableJSON, Error>? = lock.withLock {
            let c = pending[id]
            pending.removeValue(forKey: id)
            return c
        }
        guard let cont else { return }

        if let error = json["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "unknown error"
            cont.resume(throwing: MCPError.protocolError(msg))
        } else {
            cont.resume(returning: SendableJSON(value: json["result"] ?? [:]))
        }
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Server manager

/// Owns MCP server configs (~/.coucou/mcp.json), spawns enabled servers at
/// launch, and routes tool calls to the right connection.
@MainActor
final class MCPManager: ObservableObject {
    static let shared = MCPManager()

    struct ServerConfig: Codable, Identifiable {
        var id: String = UUID().uuidString
        var name: String
        var command: String
        var args: [String] = []
        var env: [String: String] = [:]
        var enabled: Bool = true
    }

    @Published private(set) var servers: [ServerConfig] = []
    /// Server ids that connected successfully (for the settings UI).
    @Published private(set) var connectedIds: Set<String> = []

    private var connections: [String: MCPConnection] = [:]
    /// Raw tool payloads per server id (populated on successful connect).
    private var toolsByServer: [String: [SendableJSON]] = [:]
    /// tool name -> (server id, raw tool payload). First server wins on collision.
    private var toolIndex: [String: (serverId: String, raw: SendableJSON)] = [:]

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".coucou/mcp.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) else {
            return
        }
        servers = decoded
    }

    private func save() {
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(servers) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    func addServer(_ config: ServerConfig) {
        servers.append(config)
        save()
        Task { await connect(config) }
    }

    func removeServer(id: String) {
        connections[id]?.stop()
        connections.removeValue(forKey: id)
        toolsByServer.removeValue(forKey: id)
        connectedIds.remove(id)
        servers.removeAll { $0.id == id }
        rebuildToolIndex()
        save()
    }

    func toggleServer(id: String) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].enabled.toggle()
        save()
        if servers[i].enabled {
            let config = servers[i]
            Task { await connect(config) }
        } else {
            connections[id]?.stop()
            connections.removeValue(forKey: id)
            toolsByServer.removeValue(forKey: id)
            connectedIds.remove(id)
            rebuildToolIndex()
        }
    }

    func reconnectAll() async {
        for (_, conn) in connections { conn.stop() }
        connections.removeAll()
        toolsByServer.removeAll()
        toolIndex.removeAll()
        connectedIds.removeAll()
        await connectAll()
    }

    func connectAll() async {
        for server in servers where server.enabled {
            await connect(server)
        }
    }

    private func connect(_ config: ServerConfig) async {
        guard connections[config.id] == nil else { return }
        let conn = MCPConnection()
        conn.name = config.name
        do {
            try conn.start(command: config.command, args: config.args, env: config.env)
            try await conn.initialize()
            let tools = try await conn.listTools()
            connections[config.id] = conn
            toolsByServer[config.id] = tools
            connectedIds.insert(config.id)
            rebuildToolIndex()
        } catch {
            conn.stop()
            // Connection failure is non-fatal; the server simply stays offline.
        }
    }

    private func rebuildToolIndex() {
        toolIndex.removeAll()
        for server in servers {
            guard connections[server.id] != nil,
                  let tools = toolsByServer[server.id] else { continue }
            for tool in tools {
                guard let dict = tool.value as? [String: Any],
                      let name = dict["name"] as? String, toolIndex[name] == nil else { continue }
                toolIndex[name] = (server.id, tool)
            }
        }
    }

    /// Definitions for the active AI provider, in provider-agnostic form.
    func toolDefinitions() -> [MCPToolDefinition] {
        toolIndex.values.compactMap { entry -> MCPToolDefinition? in
            guard let raw = entry.raw.value as? [String: Any],
                  let name = raw["name"] as? String else { return nil }
            let serverName = servers.first(where: { $0.id == entry.serverId })?.name ?? "mcp"
            return MCPToolDefinition(
                serverName: serverName,
                name: name,
                description: (raw["description"] as? String) ?? "",
                inputSchema: (raw["inputSchema"] as? [String: Any]) ?? ["type": "object"])
        }
    }

    /// Calls a tool by name. `argumentsJSON` is the raw JSON object string.
    func callTool(name: String, argumentsJSON: String) async throws -> String {
        guard let entry = toolIndex[name],
              let conn = connections[entry.serverId] else {
            throw MCPError.notRunning(name)
        }
        var args: [String: Any] = [:]
        if let data = argumentsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = parsed
        }
        return try await conn.callTool(name: name, arguments: args)
    }

    var toolCount: Int { toolIndex.count }
}
