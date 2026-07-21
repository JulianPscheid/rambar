# Rambar

A process-first memory monitor for agent-heavy Macs, as a native menu bar app, a CLI, and an MCP server.

Rambar starts with the familiar app and runtime groups needed to find a memory hog quickly. Agent rows then expand into **agent sessions**: a Claude Code, Codex, or Gemini root process plus every helper descended from it (MCP servers, shells, and dev servers). It finds sessions whether they are hosted by a desktop app, a terminal or tmux pane, or a headless worker with no TTY.

## Why process groups and sessions

When a Mac is under pressure, the first question is usually whether Claude, Chrome, an editor, or something else is responsible. Process groups answer that at a glance. Per-session attribution answers the next questions: which agent session is the memory hog, what did a closed session leave behind, and why are there 22 resident copies of the same MCP server.

Each listed process belongs to one top-level group. Agent-owned Node and Python helpers stay with their agent instead of being counted again as standalone runtimes. Rambar groups previously unknown applications from their outer `.app` bundle, so the list does not depend on a fixed app allowlist.

Group values sum macOS per-process physical footprints. Shared memory can appear in more than one process, so adding rows together can exceed the system-used number. The system header and kernel pressure remain the authoritative machine-wide signals.

## What it shows

- **Process-centric overview** — significant applications, agent families, standalone runtimes, and an unmatched “Other” bucket, sorted by physical footprint
- **Expandable agent detail** — per-session footprint across the full process tree, with hosting mode (desktop / terminal / headless), project, process count, and helper breakdown
- **Kernel pressure, not percent** — the menu bar tint and alerts key off macOS memory-pressure events; 81% used with a calm kernel is fine, and Rambar says so
- **Alerts that name the mover** — a pressure transition reports the session that grew most in the last 10 minutes, not just a level
- **Hygiene** — helpers that outlived their session (with one-click reclaim), and the same helper binary resident many times across sessions
- **History** — a 60-minute sparkline in the panel; a week of samples in SQLite for "what ate RAM overnight"

## Architecture

One repo, three consumers of one collection pipeline:

- `rambar collect` — a launchd agent sampling every 5 s via libproc syscalls (no `ps`, no parsing, no AppleScript) into `~/.rambar/rambar.sqlite`
- **Rambar.app** — a SwiftUI MenuBarExtra that only reads the store; the UI owns no collection state
- `rambar` CLI + `rambar mcp` — the same ledger for terminals and for agents themselves; a Claude session can ask how much memory it is using

`RambarKit` (process grouping, session attribution, orphan tracking, dedup, and trends) is a pure library with no system dependencies, tested against fixture topologies modeled on real machines.

## Install

```bash
git clone https://github.com/MaxGhenis/rambar.git
cd rambar
swift build -c release
./.build/release/rambar install-daemon   # start the collector (launchd)
scripts/bundle-app.sh release            # assemble dist/Rambar.app
open dist/Rambar.app                     # menu bar face
```

`rambar doctor` verifies every layer. `rambar uninstall-daemon` removes the collector and keeps your data.

## CLI

```
rambar top             # sessions and system memory (works even without the daemon)
rambar sessions --json # machine-readable session list
rambar events          # pressure transitions, orphans, session starts/ends
rambar doctor          # check collection, store freshness, launchd
rambar mcp             # MCP stdio server: memory_status, list_sessions, session_history
```

Register the MCP server so agents can read the ledger:

```bash
claude mcp add rambar -- ~/.rambar/bin/rambar mcp
```

## Requirements

- macOS 14.0+
- No special permissions: collection is same-user libproc; no AppleScript, no accessibility, no screen recording

## v1

The original monitor (Chrome tabs and the retro theme) lives in [`RAMBar/`](RAMBar/) and still builds:

```bash
cd RAMBar && xcodebuild -scheme RAMBar -configuration Release build
```

## License

[Unlicense](LICENSE) — public domain.
