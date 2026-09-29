import Foundation

// MARK: - Skill errors

enum SkillError: LocalizedError {
    case alreadyInstalled(String)
    case copyFailed(String)
    case cloneFailed(String)
    case invalidSource(String)

    var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let n): return "Skill '\(n)' is already installed."
        case .copyFailed(let m):       return "Could not copy skill: \(m)"
        case .cloneFailed(let m):      return "Git clone failed: \(m)"
        case .invalidSource(let s):    return "Not a git URL or local folder: \(s)"
        }
    }
}

// MARK: - Skill manager

/// Installable capability packs. Each skill is a folder with a SKILL.md file
/// (agent-skills format: YAML frontmatter + markdown instructions).
/// Enabled skills are injected into the assistant system prompt.
@MainActor
final class SkillManager: ObservableObject {
    static let shared = SkillManager()

    struct InstalledSkill: Codable, Identifiable {
        var id: String          // folder name under ~/.momoco/skills
        var name: String        // from SKILL.md frontmatter
        var description: String // from SKILL.md frontmatter
        var enabled: Bool = true
        var source: String      // git URL, or "local"
    }

    @Published private(set) var skills: [InstalledSkill] = []

    private let fm = FileManager.default

    var skillsDir: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent(".momoco/skills")
    }

    private var manifestURL: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent(".momoco/skills.json")
    }

    func load() {
        try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([InstalledSkill].self, from: data) else {
            // No manifest: adopt any folders that already contain SKILL.md.
            adoptExistingFolders()
            return
        }
        // Drop entries whose folder vanished.
        skills = decoded.filter { fm.fileExists(atPath: skillsDir.appendingPathComponent($0.id).path) }
    }

    private func save() {
        let dir = manifestURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(skills) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private func adoptExistingFolders() {
        guard let entries = try? fm.contentsOfDirectory(atPath: skillsDir.path) else { return }
        for entry in entries.sorted() {
            let md = skillsDir.appendingPathComponent(entry).appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: md.path) else { continue }
            let (name, desc) = parseFrontmatter(md)
            skills.append(InstalledSkill(id: entry, name: name ?? entry,
                                         description: desc ?? "", source: "local"))
        }
        save()
    }

    // MARK: Install / remove / toggle

    /// Installs from a git URL (https:// or git@) or a local folder path.
    func install(from input: String) async throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkillError.invalidSource(input) }

        let folderName = deriveFolderName(from: trimmed)
        let dest = skillsDir.appendingPathComponent(folderName)
        guard !fm.fileExists(atPath: dest.path) else {
            throw SkillError.alreadyInstalled(folderName)
        }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("git@") {
            try await gitClone(url: trimmed, dest: dest)
        } else {
            let src = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
                throw SkillError.invalidSource(trimmed)
            }
            do {
                try fm.copyItem(at: src, to: dest)
            } catch {
                throw SkillError.copyFailed(error.localizedDescription)
            }
        }

        let md = dest.appendingPathComponent("SKILL.md")
        let (name, desc) = parseFrontmatter(md)
        let skill = InstalledSkill(id: folderName, name: name ?? folderName,
                                   description: desc ?? "",
                                   source: trimmed.hasPrefix("http") || trimmed.hasPrefix("git@")
                                       ? trimmed : "local")
        skills.append(skill)
        skills.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func remove(_ skill: InstalledSkill) throws {
        try fm.removeItem(at: skillsDir.appendingPathComponent(skill.id))
        skills.removeAll { $0.id == skill.id }
        save()
    }

    func toggle(_ skill: InstalledSkill) {
        guard let i = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        skills[i].enabled.toggle()
        save()
    }

    // MARK: Prompt injection

    /// Markdown of all enabled skills, frontmatter stripped, for the system prompt.
    func promptAddition() -> String {
        let parts: [String] = skills.compactMap { skill in
            guard skill.enabled else { return nil }
            let md = skillsDir.appendingPathComponent(skill.id).appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: md, encoding: .utf8) else { return nil }
            return "## Skill: \(skill.name)\n\n" + stripFrontmatter(text)
        }
        guard !parts.isEmpty else { return "" }
        return "\n\n<installed_skills>\nThe user installed these skill packs. Follow their instructions when relevant.\n\n"
            + parts.joined(separator: "\n\n---\n\n")
            + "\n</installed_skills>"
    }

    // MARK: Helpers

    private func deriveFolderName(from input: String) -> String {
        var base = (input as NSString).lastPathComponent
        if base.hasSuffix(".git") { base = String(base.dropLast(4)) }
        if base.isEmpty || base == "/" { base = "skill" }
        // Sanitize: letters, digits, dash, underscore.
        let cleaned = base.map { c -> Character in
            (c.isLetter || c.isNumber || c == "-" || c == "_") ? c : "-"
        }
        return String(cleaned)
    }

    private func gitClone(url: String, dest: URL) async throws {
        try await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["clone", "--depth", "1", url, dest.path]
            let errPipe = Pipe()
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? "unknown error"
                throw SkillError.cloneFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }

    /// Returns (name, description) from SKILL.md YAML frontmatter.
    private func parseFrontmatter(_ url: URL) -> (String?, String?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        let body = stripFrontmatter(text, capture: true)
        var name: String?
        var desc: String?
        for line in body.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("name:") {
                name = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if t.hasPrefix("description:") {
                desc = t.dropFirst(12).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return (name, desc)
    }

    private func stripFrontmatter(_ text: String, capture: Bool = false) -> String {
        // Returns body without frontmatter; with capture=true returns the frontmatter itself.
        guard text.hasPrefix("---") else { return capture ? "" : text }
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 2, lines[0].trimmingCharacters(in: .whitespaces) == "---",
              let end = lines[1...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return capture ? "" : text
        }
        if capture {
            return lines[1..<end].joined(separator: "\n")
        }
        return lines[(end + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
