import Foundation

/// The kind of top-level row shown in the process-centric memory view.
public enum ProcessGroupKind: String, Codable, Sendable {
    case agent
    case application
    case runtime
    case other
}

/// A mutually exclusive process bucket. Agent buckets can be expanded into
/// the session records Rambar already tracks; the other buckets stay compact.
public struct ProcessGroup: Hashable, Codable, Sendable {
    public let key: String
    public let displayName: String
    public let family: AgentFamily?
    public let kind: ProcessGroupKind
    public let footprint: UInt64
    public let processCount: Int
    public let sessionCount: Int

    public init(
        key: String,
        displayName: String,
        family: AgentFamily?,
        kind: ProcessGroupKind,
        footprint: UInt64,
        processCount: Int,
        sessionCount: Int
    ) {
        self.key = key
        self.displayName = displayName
        self.family = family
        self.kind = kind
        self.footprint = footprint
        self.processCount = processCount
        self.sessionCount = sessionCount
    }
}

private struct GroupIdentity {
    let key: String
    let displayName: String
    let family: AgentFamily?
    let kind: ProcessGroupKind
}

private struct ProcessRule {
    let identity: GroupIdentity
    let matches: (String, String) -> Bool
}

private func identity(for family: AgentFamily) -> GroupIdentity {
    GroupIdentity(
        key: "agent:\(family.rawValue)",
        displayName: family.displayName,
        family: family,
        kind: .agent
    )
}

private let processRules: [ProcessRule] = [
    ProcessRule(identity: .init(key: "app:chrome", displayName: "Chrome", family: nil, kind: .application)) {
        $0.contains("/google chrome.app/") || $1.contains("google chrome")
    },
    ProcessRule(identity: .init(key: "app:brave", displayName: "Brave", family: nil, kind: .application)) {
        $0.contains("/brave browser.app/") || $1.contains("brave")
    },
    ProcessRule(identity: .init(key: "app:firefox", displayName: "Firefox", family: nil, kind: .application)) {
        $0.contains("/firefox.app/") || $1.contains("firefox")
    },
    ProcessRule(identity: .init(key: "app:safari", displayName: "Safari", family: nil, kind: .application)) {
        $0.contains("/safari.app/") || $1 == "safari"
    },
    ProcessRule(identity: .init(key: "app:arc", displayName: "Arc", family: nil, kind: .application)) { path, _ in
        path.contains("/arc.app/")
    },
    ProcessRule(identity: .init(key: "app:cursor", displayName: "Cursor", family: nil, kind: .application)) {
        $0.contains("/cursor.app/") || $1.hasPrefix("cursor helper")
    },
    ProcessRule(identity: .init(key: "app:vscode", displayName: "VS Code", family: nil, kind: .application)) {
        $0.contains("/visual studio code.app/") || $1.hasPrefix("code helper")
    },
    ProcessRule(identity: .init(key: "app:slack", displayName: "Slack", family: nil, kind: .application)) {
        $0.contains("/slack.app/") || $1.hasPrefix("slack")
    },
    ProcessRule(identity: .init(key: "app:granola", displayName: "Granola", family: nil, kind: .application)) {
        $0.contains("/granola.app/") || $1.hasPrefix("granola")
    },
    ProcessRule(identity: .init(key: "app:docker", displayName: "Docker", family: nil, kind: .application)) {
        $0.contains("/docker.app/") || $1.hasPrefix("docker")
    },
    ProcessRule(identity: .init(key: "app:whatsapp", displayName: "WhatsApp", family: nil, kind: .application)) {
        $0.contains("/whatsapp.app/") || $1.hasPrefix("whatsapp")
    },
    ProcessRule(identity: .init(key: "app:obsidian", displayName: "Obsidian", family: nil, kind: .application)) {
        $0.contains("/obsidian.app/") || $1.hasPrefix("obsidian")
    },
    ProcessRule(identity: .init(key: "app:warp", displayName: "Warp", family: nil, kind: .application)) {
        $0.contains("/warp.app/") || $1.hasPrefix("warp")
    },
    ProcessRule(identity: .init(key: "app:ghostty", displayName: "Ghostty", family: nil, kind: .application)) {
        $0.contains("/ghostty.app/") || $1.hasPrefix("ghostty")
    },
    ProcessRule(identity: .init(key: "app:iterm", displayName: "iTerm", family: nil, kind: .application)) {
        $0.contains("/iterm.app/") || $0.contains("/iterm2.app/") || $1.hasPrefix("iterm")
    },
    ProcessRule(identity: .init(key: "app:figma", displayName: "Figma", family: nil, kind: .application)) {
        $0.contains("/figma.app/") || $1.hasPrefix("figma")
    },
    ProcessRule(identity: .init(key: "app:zoom", displayName: "Zoom", family: nil, kind: .application)) {
        $0.contains("/zoom.app/") || $1.hasPrefix("zoom")
    },
    ProcessRule(identity: .init(key: "app:discord", displayName: "Discord", family: nil, kind: .application)) {
        $0.contains("/discord.app/") || $1.hasPrefix("discord")
    },
    ProcessRule(identity: .init(key: "app:spotify", displayName: "Spotify", family: nil, kind: .application)) {
        $0.contains("/spotify.app/") || $1.hasPrefix("spotify")
    },
    ProcessRule(identity: .init(key: "runtime:python", displayName: "Python", family: nil, kind: .runtime)) {
        $1.hasPrefix("python")
    },
    ProcessRule(identity: .init(key: "runtime:node", displayName: "Node.js", family: nil, kind: .runtime)) {
        $1 == "node" || $1 == "bun" || $1 == "deno"
    },
]

private func hostFamily(for lowerPath: String) -> AgentFamily? {
    if lowerPath.contains("/claude.app/") { return .claude }
    if lowerPath.contains("/codex.app/") { return .codex }
    if lowerPath.contains("/gemini.app/") { return .gemini }
    return nil
}

private let appAliases: [String: (key: String, displayName: String)] = [
    "brave browser": ("brave", "Brave"),
    "google chrome": ("chrome", "Chrome"),
    "iterm2": ("iterm", "iTerm"),
    "visual studio code": ("vscode", "VS Code"),
]

/// Use the outer application bundle, not a nested Electron helper bundle.
/// This keeps the list useful for apps that were not known when Rambar was
/// released, without growing a permanent allowlist.
private func applicationIdentity(for path: String) -> GroupIdentity? {
    guard let component = path.split(separator: "/").first(where: {
        $0.lowercased().hasSuffix(".app")
    }) else { return nil }

    let bundleName = String(component.dropLast(4))
    let normalized = bundleName.lowercased()
    let alias = appAliases[normalized]
    let slug = normalized.map { character -> Character in
        character.isLetter || character.isNumber ? character : "-"
    }
    let generatedKey = String(slug).split(separator: "-").joined(separator: "-")
    return GroupIdentity(
        key: "app:\(alias?.key ?? generatedKey)",
        displayName: alias?.displayName ?? bundleName,
        family: nil,
        kind: .application
    )
}

/// Partition a process table into the app-style groups people use to find a
/// memory hog. Session membership wins over executable matching, so a Node or
/// Python helper owned by an agent never appears in two rows. Agent desktop
/// hosts are folded into the same family row even though they are ancestors,
/// not descendants, of their engine sessions.
public func buildProcessGroups(
    samples: [ProcessSample],
    sessionTrees: [AgentSessionTree],
    otherThresholdBytes: UInt64 = 500 * 1_048_576,
    minimumGroupBytes: UInt64 = 50 * 1_048_576
) -> [ProcessGroup] {
    var uniqueSamples: [Int32: ProcessSample] = [:]
    for sample in samples where sample.pid > 0 {
        uniqueSamples[sample.pid] = uniqueSamples[sample.pid] ?? sample
    }

    var ownedFamilyByPid: [Int32: AgentFamily] = [:]
    var sessionCountByFamily: [AgentFamily: Int] = [:]
    for tree in sessionTrees {
        sessionCountByFamily[tree.family, default: 0] += 1
        for member in tree.members {
            ownedFamilyByPid[member.pid] = ownedFamilyByPid[member.pid] ?? tree.family
        }
    }

    var identities: [String: GroupIdentity] = [:]
    var footprints: [String: UInt64] = [:]
    var counts: [String: Int] = [:]
    var unmatchedFootprint: UInt64 = 0
    var unmatchedCount = 0

    for sample in uniqueSamples.values {
        let lowerPath = sample.execPath.lowercased()
        let basename = sample.executableBasename.lowercased()
        let groupIdentity: GroupIdentity?

        if let family = ownedFamilyByPid[sample.pid]
            ?? hostFamily(for: lowerPath)
            ?? agentFamily(forExecutablePath: sample.execPath) {
            groupIdentity = identity(for: family)
        } else if let application = applicationIdentity(for: sample.execPath) {
            groupIdentity = application
        } else {
            groupIdentity = processRules.first { $0.matches(lowerPath, basename) }?.identity
        }

        guard let groupIdentity else {
            unmatchedFootprint += sample.footprint
            unmatchedCount += 1
            continue
        }
        identities[groupIdentity.key] = groupIdentity
        footprints[groupIdentity.key, default: 0] += sample.footprint
        counts[groupIdentity.key, default: 0] += 1
    }

    if unmatchedFootprint > otherThresholdBytes {
        let other = GroupIdentity(key: "other", displayName: "Other", family: nil, kind: .other)
        identities[other.key] = other
        footprints[other.key] = unmatchedFootprint
        counts[other.key] = unmatchedCount
    }

    return identities.values.map { identity in
        ProcessGroup(
            key: identity.key,
            displayName: identity.displayName,
            family: identity.family,
            kind: identity.kind,
            footprint: footprints[identity.key] ?? 0,
            processCount: counts[identity.key] ?? 0,
            sessionCount: identity.family.flatMap { sessionCountByFamily[$0] } ?? 0
        )
    }
    .filter {
        $0.kind == .agent || $0.kind == .other || $0.footprint >= minimumGroupBytes
    }
    .sorted {
        if $0.footprint == $1.footprint { return $0.displayName < $1.displayName }
        return $0.footprint > $1.footprint
    }
}
