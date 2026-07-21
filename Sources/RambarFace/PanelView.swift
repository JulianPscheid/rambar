import SwiftUI
import RambarKit
import RambarSystem

/// The popover panel. System typography throughout; numbers set in monospaced
/// digits (telemetry register), labels in text register. Color appears only
/// where it carries a referent: kernel pressure and threshold crossings.
struct PanelView: View {
    @ObservedObject var model: FaceModel
    /// ImageRenderer cannot draw ScrollView content or Menu controls; the
    /// --snapshot path renders a flat, bounded list instead.
    var snapshotMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 10)

            Divider()

            if model.collectorNeedsUpdate {
                VStack(spacing: 5) {
                    Text("collector update required")
                        .font(.callout.weight(.medium))
                    Text("Run the bundled rambar-cli install-daemon command")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if !model.hasProcessGroupSnapshot {
                Text("waiting for process sample")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else if model.processGroups.isEmpty {
                Text("no significant process groups")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else if snapshotMode {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(snapshotGroups, id: \.key) { group in
                        processGroupRow(group)
                    }
                    if model.processGroups.count > snapshotRowLimit {
                        Text("… and \(model.processGroups.count - snapshotRowLimit) more groups")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.processGroups, id: \.key) { group in
                            processGroupRow(group)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                // ScrollView has no intrinsic height and collapses inside a
                // MenuBarExtra window — size it to the content, capped.
                .frame(height: sessionListHeight)
            }

            if hasHygiene {
                Divider()
                hygiene
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: 344)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let system = model.system {
                    Text(gbNumber(system.used))
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(gbNumber(system.total)) GB")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("waiting for first sample")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                pressureBadge
            }

            SparklineView(
                points: model.history.map { ($0.ts, Double($0.used) / Double(max($0.total, 1))) },
                tint: model.pressure.tint
            )
            .frame(height: 26)

            if let system = model.system {
                Text("compressed \(formatBytes(system.compressed))"
                    + " · \(model.processGroups.count) process groups")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pressureBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.pressure.tint)
                .frame(width: 6, height: 6)
            Text(model.pressure.label)
                .font(.caption.weight(.medium))
                .monospaced()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .help("Kernel memory-pressure level — the signal that matters, not the raw percent")
    }

    // MARK: - Process groups and sessions

    private func processGroupRow(_ group: ProcessGroup) -> some View {
        let expanded = model.expandedGroupKey == group.key
        return VStack(alignment: .leading, spacing: 0) {
            if group.family != nil {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        model.toggleExpansion(group)
                    }
                } label: {
                    processGroupLabel(group, expanded: expanded)
                }
                .buttonStyle(.plain)
            } else {
                processGroupLabel(group, expanded: false)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 1) {
                    if group.hostProcessCount > 0 {
                        hostRow(group)
                    }
                    ForEach(model.sessions(for: group), id: \.key) { session in
                        sessionRow(session)
                    }
                    if model.sessions(for: group).isEmpty {
                        Text("no active session details")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.leading, 10)
            }
        }
    }

    private func hostRow(_ group: ProcessGroup) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("shared background")
                    .font(.system(size: 13, weight: .medium))
                Text("\(group.hostProcessCount) procs outside chat trees")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(formatBytes(group.hostFootprint))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    private func processGroupLabel(_ group: ProcessGroup, expanded: Bool) -> some View {
        HStack(spacing: 8) {
            Text(group.displayName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Text(groupCountLabel(group))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))

            Spacer(minLength: 8)

            Text(formatBytes(group.footprint))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(group.footprint >= sessionFootprintWarningBytes ? .orange : .primary)
                .help("Sum of macOS process footprints; shared memory can appear in more than one row")

            if group.family != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(expanded ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func groupCountLabel(_ group: ProcessGroup) -> String {
        if group.family != nil {
            return group.sessionCount == 1 ? "1 session" : "\(group.sessionCount) sessions"
        }
        return group.processCount == 1 ? "1 proc" : "\(group.processCount) procs"
    }

    private func sessionRow(_ session: SessionRecord) -> some View {
        let expanded = model.expandedKey == session.key
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    model.toggleExpansion(session)
                }
            } label: {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(session.title ?? session.project)
                        Text(subtitle(for: session))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if model.rising.contains(session.key) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .help("Grew ≥ 1 MB/min over the last 10 minutes")
                    }
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(formatBytes(session.footprint))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(session.needsAttention ? .orange : .primary)
                        Text("\(session.processCount) procs")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(expanded ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    if let id = session.sessionID {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("session ID")
                                .foregroundStyle(.tertiary)
                            Text(id)
                                .monospaced()
                                .textSelection(.enabled)
                        }
                        .font(.caption2)
                        .padding(.bottom, 2)
                    }
                    ForEach(model.expandedChildren, id: \.pid) { child in
                        HStack {
                            Text(child.commandLabel)
                                .lineLimit(1)
                            Spacer()
                            Text(formatBytes(child.footprint))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if model.expandedChildren.isEmpty {
                        Text("no helper processes")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
            }
        }
    }

    private func subtitle(for session: SessionRecord) -> String {
        var parts: [String] = []
        // When the title leads, the project still earns its place below —
        // unless it is just "~", which says nothing.
        if session.title != nil, session.project != "~" {
            parts.append(session.project)
        }
        parts.append(session.mode.label)
        if let id = session.sessionID {
            parts.append(String(id.prefix(8)))
        } else {
            parts.append("pid \(session.rootPid)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Hygiene

    private var hasHygiene: Bool {
        (model.orphans?.count ?? 0) > 0 || !(model.orphans?.duplicates.isEmpty ?? true)
    }

    @State private var confirmingReclaim = false

    private var hygiene: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let orphans = model.orphans, orphans.count > 0 {
                HStack {
                    Label {
                        Text("\(orphans.count) helpers outlived their session · \(formatBytes(orphans.footprint))")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "moon.zzz")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                    Spacer()
                    Button("Reclaim") { confirmingReclaim = true }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .confirmationDialog(
                            "Send SIGTERM to \(orphans.count) orphaned helper processes?",
                            isPresented: $confirmingReclaim
                        ) {
                            Button("Terminate helpers", role: .destructive) {
                                model.reclaimOrphans()
                            }
                        }
                }
            }
            if let dups = model.orphans?.duplicates, !dups.isEmpty {
                let named = dups.filter {
                    !$0.basename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                ForEach(Array(named.prefix(3)), id: \.stableKey) { dup in
                    Label {
                        Text("\(dup.basename) ×\(dup.count) · \(formatBytes(dup.footprint))")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("The same helper is resident \(dup.count) times across sessions")
                }
                if named.count > 3 {
                    Text("… and \(named.count - 3) more duplicate helper groups")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if model.collectorNeedsUpdate {
                Label("collector update required", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if model.collectorRunning {
                Text("sampled \(Int(max(model.sampledAgo, 0)))s ago")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            } else {
                Label("collector not running — rambar install-daemon", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if !snapshotMode {
                Menu {
                    Button("Refresh now") { model.refresh() }
                    Divider()
                    Button("Quit Rambar") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var sessionListHeight: CGFloat {
        let rows = CGFloat(model.processGroups.count) * 38
        let expandedSessions = model.processGroups.first { $0.key == model.expandedGroupKey }
            .map { model.sessions(for: $0).count } ?? 0
        let sessionRows = CGFloat(expandedSessions) * 38
        let expandedHostCount = model.processGroups.first { $0.key == model.expandedGroupKey }?
            .hostProcessCount ?? 0
        let hostRows: CGFloat = expandedHostCount > 0 ? 38 : 0
        let childRows = model.expandedKey == nil
            ? 0
            : CGFloat(max(model.expandedChildren.count, 1)) * 20 + 10
        return min(rows + sessionRows + hostRows + childRows + 16, 380)
    }

    private let snapshotRowLimit = 12

    private var snapshotGroups: [ProcessGroup] {
        Array(model.processGroups.prefix(snapshotRowLimit))
    }

    private func gbNumber(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}
