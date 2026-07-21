import Foundation
import RambarKit

public struct IndexedSessionIdentity: Equatable, Sendable {
    public let sessionID: String?
    public let title: String?

    public init(sessionID: String?, title: String?) {
        self.sessionID = sessionID
        self.title = title
    }
}

/// Resolves running roots to the agents' local session metadata.
///
/// Claude keeps one transcript per session under a cwd-derived directory;
/// Codex keeps rollout metadata plus a separate ID-to-thread-name index.
/// Resolution is batched so multiple roots in one project remain one-to-one.
public struct SessionIndex {
    private struct Candidate {
        let family: AgentFamily
        let id: String
        let cwd: String
        let startedAt: Double?
        let title: String?
    }

    private struct ClaudeMetadata {
        let startedAt: Double?
        let title: String?
    }

    private let fileManager: FileManager
    private let claudeProjectsRoot: String
    private let codexRoot: String
    private let matchWindow: TimeInterval = 10 * 60

    public init(home: String, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.claudeProjectsRoot = home + "/.claude/projects"
        self.codexRoot = home + "/.codex"
    }

    public static func encodeClaudeProjectDirectory(cwd: String) -> String {
        String(cwd.map { character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        })
    }

    /// Resolve a batch so concurrent sessions in one working directory are
    /// matched one-to-one instead of all claiming the newest transcript.
    /// Explicit resume IDs win; otherwise the closest transcript/rollout
    /// start within ten minutes is used.
    public func identities(
        for trees: [AgentSessionTree],
        knownSessionIDs: [String: String] = [:]
    ) -> [String: IndexedSessionIdentity] {
        guard !trees.isEmpty else { return [:] }

        let hints = Dictionary(uniqueKeysWithValues: trees.compactMap { tree in
            (tree.root.sessionIDHint ?? knownSessionIDs[tree.key]).map { (tree.key, $0) }
        })
        let candidates = claudeCandidates(for: trees, hints: hints)
            + codexCandidates(for: trees, hints: hints)
        var candidateByFamilyAndID: [String: Candidate] = [:]
        for candidate in candidates {
            candidateByFamilyAndID["\(candidate.family.rawValue):\(candidate.id)"] = candidate
        }

        var result: [String: IndexedSessionIdentity] = [:]
        var claimedCandidates: Set<String> = []

        for tree in trees {
            guard let hint = hints[tree.key] else { continue }
            let candidateKey = "\(tree.family.rawValue):\(hint)"
            guard !claimedCandidates.contains(candidateKey),
                  let candidate = candidateByFamilyAndID[candidateKey] else {
                continue
            }
            result[tree.key] = IndexedSessionIdentity(
                sessionID: candidate.id,
                title: candidate.title
            )
            claimedCandidates.insert(candidateKey)
        }

        let edges = trees.flatMap { tree -> [(tree: AgentSessionTree, candidate: Candidate, delta: Double)] in
            guard result[tree.key] == nil, let cwd = tree.root.cwd else { return [] }
            return candidates.compactMap { candidate in
                let candidateKey = "\(candidate.family.rawValue):\(candidate.id)"
                guard candidate.family == tree.family,
                      candidate.cwd == cwd,
                      !claimedCandidates.contains(candidateKey),
                      let startedAt = candidate.startedAt else { return nil }
                let delta = abs(startedAt - tree.root.startTime)
                guard delta <= matchWindow else { return nil }
                return (tree, candidate, delta)
            }
        }.sorted {
            if $0.delta == $1.delta {
                if $0.tree.key == $1.tree.key { return $0.candidate.id < $1.candidate.id }
                return $0.tree.key < $1.tree.key
            }
            return $0.delta < $1.delta
        }

        var matchedTrees: Set<String> = Set(result.keys)
        for edge in edges {
            let candidateKey = "\(edge.candidate.family.rawValue):\(edge.candidate.id)"
            guard !matchedTrees.contains(edge.tree.key),
                  !claimedCandidates.contains(candidateKey) else { continue }
            result[edge.tree.key] = IndexedSessionIdentity(
                sessionID: edge.candidate.id,
                title: edge.candidate.title
            )
            matchedTrees.insert(edge.tree.key)
            claimedCandidates.insert(candidateKey)
        }

        for tree in trees where result[tree.key] == nil
            && tree.family == .codex && tree.mode == .desktop {
            result[tree.key] = IndexedSessionIdentity(sessionID: nil, title: "Codex desktop")
        }
        return result
    }

    private func claudeDirectory(cwd: String) -> String {
        claudeProjectsRoot + "/" + Self.encodeClaudeProjectDirectory(cwd: cwd)
    }

    private func claudeCandidates(
        for trees: [AgentSessionTree],
        hints: [String: String]
    ) -> [Candidate] {
        let claudeTrees = trees.filter { $0.family == .claude && $0.root.cwd != nil }
        let byCwd = Dictionary(grouping: claudeTrees, by: { $0.root.cwd! })
        var candidates: [Candidate] = []

        for (cwd, cwdTrees) in byCwd {
            let directory = claudeDirectory(cwd: cwd)
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            let hintedIDs = Set(cwdTrees.compactMap { hints[$0.key] })
            let unhintedTrees = cwdTrees.filter { hints[$0.key] == nil }
            for entry in entries where entry.hasSuffix(".jsonl") {
                let id = String(entry.dropLast(".jsonl".count))
                let path = directory + "/" + entry
                let hinted = hintedIDs.contains(id)
                if !hinted {
                    guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                          let created = attributes[.creationDate] as? Date,
                          unhintedTrees.contains(where: {
                              abs(created.timeIntervalSince1970 - $0.root.startTime) <= matchWindow
                          }) else { continue }
                }
                guard let metadata = claudeMetadata(at: path) else { continue }
                candidates.append(Candidate(
                    family: .claude,
                    id: id,
                    cwd: cwd,
                    startedAt: metadata.startedAt,
                    title: metadata.title
                ))
            }
        }
        return candidates
    }

    private func claudeMetadata(at path: String) -> ClaudeMetadata? {
        guard let data = transcriptSlices(at: path) else { return nil }
        var customTitle: String?
        var aiTitle: String?
        var agentName: String?
        var firstPrompt: String?
        var startedAt: Double?

        for lineData in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(lineData))
                    as? [String: Any] else { continue }
            if let timestamp = timestamp(entry["timestamp"]) {
                startedAt = min(startedAt ?? timestamp, timestamp)
            }
            switch entry["type"] as? String {
            case "custom-title":
                customTitle = (entry["customTitle"] as? String).flatMap(cleanTitle)
            case "ai-title":
                aiTitle = aiTitle ?? (entry["aiTitle"] as? String).flatMap(cleanTitle)
            case "agent-name":
                agentName = agentName ?? (entry["agentName"] as? String).flatMap(cleanTitle)
            case "queue-operation":
                firstPrompt = firstPrompt
                    ?? (entry["content"] as? String).flatMap(cleanTitle)
            case "user":
                guard firstPrompt == nil else { continue }
                let message = entry["message"] as? [String: Any]
                if let text = message?["content"] as? String {
                    firstPrompt = cleanTitle(text)
                } else if let blocks = message?["content"] as? [[String: Any]],
                          let text = blocks.first(where: {
                              $0["type"] as? String == "text"
                          })?["text"] as? String {
                    firstPrompt = cleanTitle(text)
                }
            default:
                continue
            }
        }
        return ClaudeMetadata(
            startedAt: startedAt,
            title: customTitle ?? aiTitle ?? agentName ?? firstPrompt
        )
    }

    private func transcriptSlices(at path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512 * 1024) else { return nil }
        var data = head
        guard let size = try? handle.seekToEnd(), size > UInt64(head.count) else { return data }
        let tailSize: UInt64 = 256 * 1024
        guard (try? handle.seek(toOffset: size > tailSize ? size - tailSize : 0)) != nil,
              let tail = try? handle.read(upToCount: Int(tailSize)) else { return data }
        data.append(UInt8(ascii: "\n"))
        data.append(tail)
        return data
    }

    private func codexCandidates(
        for trees: [AgentSessionTree],
        hints: [String: String]
    ) -> [Candidate] {
        let codexTrees = trees.filter { $0.family == .codex && $0.root.cwd != nil }
        guard !codexTrees.isEmpty,
              let enumerator = fileManager.enumerator(atPath: codexRoot + "/sessions") else {
            return []
        }
        let names = codexThreadNames()
        let hintedIDs = Set(codexTrees.compactMap { hints[$0.key] })
        let unhintedTrees = codexTrees.filter { hints[$0.key] == nil }
        var candidates: [Candidate] = []

        for case let relativePath as String in enumerator {
            guard relativePath.hasSuffix(".jsonl"),
                  relativePath.contains("rollout-") else { continue }
            let path = codexRoot + "/sessions/" + relativePath
            let filename = (relativePath as NSString).lastPathComponent
            let hinted = hintedIDs.contains { filename.contains($0) }
            if !hinted {
                guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                      let created = attributes[.creationDate] as? Date,
                      unhintedTrees.contains(where: {
                          abs(created.timeIntervalSince1970 - $0.root.startTime) <= matchWindow
                      }) else { continue }
            }
            guard let metadata = codexRolloutMetadata(at: path) else { continue }
            candidates.append(Candidate(
                family: .codex,
                id: metadata.id,
                cwd: metadata.cwd,
                startedAt: metadata.startedAt,
                title: names[metadata.id] ?? metadata.fallbackTitle
            ))
        }
        return candidates
    }

    private func codexRolloutMetadata(
        at path: String
    ) -> (id: String, cwd: String, startedAt: Double, fallbackTitle: String?)? {
        guard let handle = FileHandle(forReadingAtPath: path),
              let data = try? handle.read(upToCount: 512 * 1024) else { return nil }
        defer { try? handle.close() }
        var id: String?
        var cwd: String?
        var startedAt: Double?
        var originator: String?
        var firstPrompt: String?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                  let payload = entry["payload"] as? [String: Any] else { continue }
            if entry["type"] as? String == "session_meta" {
                id = payload["id"] as? String
                cwd = payload["cwd"] as? String
                startedAt = timestamp(payload["timestamp"] ?? entry["timestamp"])
                originator = payload["originator"] as? String
            } else if entry["type"] as? String == "event_msg",
                      payload["type"] as? String == "user_message",
                      firstPrompt == nil,
                      let message = payload["message"] as? String {
                firstPrompt = cleanTitle(message)
            }
        }
        guard let id, let cwd, let startedAt else { return nil }
        let processTitle = originator == "codex_exec" ? "Codex exec" : nil
        return (id, cwd, startedAt, firstPrompt ?? processTitle)
    }

    private func codexThreadNames() -> [String: String] {
        let path = codexRoot + "/session_index.jsonl"
        guard let data = fileManager.contents(atPath: path) else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = entry["id"] as? String,
                  let rawName = entry["thread_name"] as? String,
                  let name = cleanTitle(rawName) else { continue }
            names[id] = name
        }
        return names
    }

    private func timestamp(_ value: Any?) -> Double? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)?.timeIntervalSince1970
    }
}

/// Strip markup (slash-command wrappers), collapse whitespace, truncate.
func cleanTitle(_ raw: String) -> String? {
    var text = raw
    while let open = text.firstIndex(of: "<"), let close = text[open...].firstIndex(of: ">") {
        text.removeSubrange(open...close)
    }
    let collapsed = text
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    return collapsed.count > 60 ? String(collapsed.prefix(59)) + "…" : collapsed
}
