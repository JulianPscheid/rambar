import Foundation
import SwiftUI
import UserNotifications
import RambarKit
import RambarSystem

/// The face's entire data layer: a periodic read of the store. It owns no
/// collection state — the class of bug where UI timers drive sampling (and
/// end up running against orphaned view models) cannot exist here.
@MainActor
final class FaceModel: ObservableObject {
    @Published var system: SystemRecord?
    @Published var sessions: [SessionRecord] = []
    @Published var history: [SystemRecord] = []
    @Published var orphans: Store.OrphanState?
    @Published var rising: Set<String> = []
    @Published var collectorRunning = false
    @Published var sampledAgo: Double = .infinity
    @Published var notificationsEnabled: Bool

    /// Children shown when a session row expands, sampled on demand.
    @Published var expandedKey: String?
    @Published var expandedChildren: [ProcessSample] = []

    private var store: Store?
    private var timer: Timer?
    private var lastNotifiedEventTs: Double
    private let notificationsAvailable: Bool
    private let reclaimFreshnessWindow: Double = 20
    private let defaults: UserDefaults

    private static let notificationsEnabledKey = "notificationsEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notificationsEnabled = defaults.object(
            forKey: Self.notificationsEnabledKey
        ) as? Bool ?? false
        lastNotifiedEventTs = defaults.double(forKey: "lastNotifiedEventTs")
        if lastNotifiedEventTs == 0 {
            lastNotifiedEventTs = Date().timeIntervalSince1970
        }
        // UNUserNotificationCenter aborts in unbundled binaries (swift run);
        // notifications only make sense from the installed app anyway.
        notificationsAvailable = Bundle.main.bundleIdentifier != nil

        if notificationsAvailable && notificationsEnabled {
            requestNotificationAuthorization()
        }
    }

    func start(interval: TimeInterval = 5) {
        refresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        if store == nil {
            store = try? Store(path: Store.defaultPath())
        }
        guard let store else {
            collectorRunning = false
            return
        }

        let now = Date().timeIntervalSince1970
        let latest = store.latestSystem()
        sampledAgo = latest.map { now - $0.ts } ?? .infinity
        collectorRunning = sampledAgo <= 20

        guard collectorRunning else {
            // Show whatever the store last knew, clearly marked stale by the footer.
            system = latest
            sessions = store.activeSessions(now: latest?.ts ?? now)
            history = store.systemHistory(since: now - 3_600)
            orphans = store.latestOrphanState()
            return
        }

        system = latest
        sessions = store.activeSessions(now: now)
        history = store.systemHistory(since: now - 3_600)
        orphans = store.latestOrphanState()

        var nowRising: Set<String> = []
        for session in sessions {
            let points = store.sessionHistory(key: session.key, since: now - 600)
            if isRising(slopeBytesPerSecond: footprintSlope(points)) {
                nowRising.insert(session.key)
            }
        }
        rising = nowRising

        notifyNewEvents(store: store)
    }

    // MARK: - Expansion

    func toggleExpansion(_ session: SessionRecord) {
        if expandedKey == session.key {
            expandedKey = nil
            expandedChildren = []
            return
        }
        expandedKey = session.key
        // One user-initiated live sample; the panel is otherwise store-only.
        let trees = buildSessionTrees(collectProcessSamples())
        let children = trees.first { $0.key == session.key }?.children ?? []
        expandedChildren = Array(children.sorted { $0.footprint > $1.footprint }.prefix(6))
    }

    // MARK: - Orphan reclaim

    var canReclaimOrphans: Bool {
        guard collectorRunning, let orphans, orphans.count > 0 else { return false }
        return orphans.isFresh(
            now: Date().timeIntervalSince1970,
            maxAge: reclaimFreshnessWindow
        )
    }

    func reclaimOrphans() {
        guard canReclaimOrphans, let orphans else { return }
        let samples = collectProcessSamples()
        let reclaimable = reclaimableOrphanIdentities(
            recorded: Set(orphans.identities),
            samples: samples,
            trees: buildSessionTrees(samples)
        )
        for identity in reclaimable {
            kill(identity.pid, SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Notifications

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        defaults.set(enabled, forKey: Self.notificationsEnabledKey)
        guard notificationsAvailable else { return }
        if enabled {
            requestNotificationAuthorization()
        } else {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    private func notifyNewEvents(store: Store) {
        let events = store.events(since: lastNotifiedEventTs)
        guard !events.isEmpty else { return }
        let batch = notificationBatch(
            events: events,
            enabled: notificationsAvailable && notificationsEnabled
        )
        if let updatedThrough = batch.updatedThrough {
            lastNotifiedEventTs = updatedThrough
            defaults.set(updatedThrough, forKey: "lastNotifiedEventTs")
        }

        for message in batch.messages {
            let content = UNMutableNotificationContent()
            content.title = message.title
            content.body = message.body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: message.identifier,
                content: content,
                trigger: nil
            ))
        }
    }

    // MARK: - Derived display values

    var usedPercentText: String {
        guard let system, system.total > 0 else { return "–" }
        return formatPercent(Double(system.used) / Double(system.total))
    }

    var pressure: PressureLevel { system?.pressure ?? .normal }

    var attributedTotal: UInt64 { sessions.reduce(0) { $0 + $1.footprint } }

    var familyGroups: [(family: AgentFamily, sessions: [SessionRecord])] {
        AgentFamily.allCases.compactMap { family in
            let members = sessions.filter { $0.family == family }
            return members.isEmpty ? nil : (family, members)
        }
    }
}

extension PressureLevel {
    var tint: Color {
        switch self {
        case .normal: return .green
        case .warn: return .orange
        case .critical: return .red
        }
    }
}
