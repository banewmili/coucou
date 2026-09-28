# Coucou fork notes (coucou-dev)

Fork of [Louis-CFM/coucou](https://github.com/Louis-CFM/coucou) (MIT) with three additions.
Upstream files untouched except `ClaudeService.swift`, `SettingsView.swift`, `AppDelegate.swift`.

## What was added

### 1. Multi-provider AI (`AIProvider.swift`)
Settings > AI Provider now offers three providers instead of Anthropic-only:
- **Anthropic** — direct Messages API (unchanged behavior, incl. web search).
- **OpenRouter** — via `https://openrouter.ai/api/v1` (OpenAI-compatible chat
  completions + `HTTP-Referer`/`X-Title` headers). One key, 300+ models.
- **OpenAI-compatible** — any base URL + key + model. Covers OpenAI, Groq,
  DeepSeek, Ollama (`http://localhost:11434/v1`), etc.

Per-provider model id is editable. Secrets stay in the macOS Keychain
(`openrouter-api-key`, `openaicomp-api-key`); the rest lives in UserDefaults
(`coucou.ai-provider-settings`). Switching provider clears the conversation.

### 2. Installable skills (`SkillManager.swift`)
Settings > Skills. Installs agent-skills packs from a git URL or a local folder
into `~/.coucou/skills/<name>/`. `SKILL.md` frontmatter (`name:`, `description:`)
is parsed; enabled skills are injected into the assistant system prompt inside
`<installed_skills>`. Toggle / remove per skill. Manifest: `~/.coucou/skills.json`.

### 3. MCP client (`MCPClient.swift`)
Settings > MCP Servers. Full JSON-RPC 2.0 client over stdio:
`initialize` -> `notifications/initialized` -> `tools/list` -> `tools/call`.
Add a server with name + command + args (e.g. `npx -y @modelcontextprotocol/server-filesystem /tmp`).
Servers spawn at app launch; green/gray dot shows connection state.
`Reconnect all` respawns everything. Config: `~/.coucou/mcp.json`.

The chat gained an **agentic tool loop** (max 8 rounds): the model can call MCP
tools, results feed back into the conversation, until it answers. Tool names are
kept as-is; on collision the first connected server wins.

## Files
- New: `NotchBuddy/Sources/App/AIProvider.swift`, `MCPClient.swift`, `SkillManager.swift`
- Modified: `ClaudeService.swift` (routes through `AIProviderClient`, tool loop),
  `SettingsView.swift` (AI Provider / Skills / MCP sections),
  `AppDelegate.swift` (loads skills + MCP at launch).
- XcodeGen globs `Sources/`, so no `project.yml` change was needed.

## Build & test (needs a Mac)
```bash
cd coucou-dev/NotchBuddy
brew install xcodegen
xcodegen
open NotchBuddy.xcodeproj   # Cmd+R
```
Not build-verified: this was written on a Linux VM without Xcode. Review the
three new files once before shipping; the riskiest area is `MCPConnection`
(stdio framing, continuation bookkeeping).

## Suggested first checks on a Mac
1. Settings > AI Provider > OpenRouter: paste `sk-or-v1-...` key, model
   `anthropic/claude-sonnet-4`, ask something in the notch.
2. Settings > MCP Servers: add `npx -y @modelcontextprotocol/server-filesystem /tmp`,
   ask "list files in /tmp" and approve the tool call.
3. Settings > Skills: install a skill repo URL, ask something the skill covers.
