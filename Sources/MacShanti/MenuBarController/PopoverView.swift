import SwiftUI

/// The popover shown when the menubar dot is clicked: actionable
/// recommendations (under pressure), aggregate memory + swap, and a ranked list
/// of the top 5 memory-consuming apps.
struct PopoverView: View {
    @ObservedObject var state: MonitorState
    var onQuitApp: (Int32) -> Void
    var onNeverSuggest: (String) -> Void
    var onQuitSelf: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let snapshot = state.snapshot {
                if snapshot.trend.isEarlyWarning {
                    predictiveBanner(snapshot)
                }
                if !state.recommendations.isEmpty {
                    recommendations
                    Divider()
                } else if snapshot.pressure == .normal {
                    healthyBanner
                    Divider()
                }
                memorySummary(snapshot)
                Divider()
                topApps(snapshot)
            } else {
                Text("Collecting first sample…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.pressure.color)
                .frame(width: 10, height: 10)
            Text("MacShanti")
                .font(.headline)
            Spacer()
            Text(state.pressure.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Recommendations

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommended actions")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(state.recommendations) { rec in
                recommendationRow(rec)
            }
        }
    }

    private func recommendationRow(_ rec: Recommendation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: rec.kind))
                .foregroundStyle(color(for: rec.kind))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.title)
                    .font(.callout.weight(.medium))
                if let detail = rec.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let label = rec.actionLabel, let pid = rec.pid {
                Button(label) { onQuitApp(pid) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .contextMenu {
            if let name = rec.appName {
                Button("Never suggest \(name)") { onNeverSuggest(name) }
            }
        }
    }

    private func predictiveBanner(_ s: Snapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.downtrend.xyaxis")
                .foregroundStyle(.orange)
            if let mins = s.trend.headroomMinutes {
                Text("Memory filling — about **\(mins) min** of headroom left. Act now to stay ahead.")
                    .font(.caption)
            } else {
                Text("Memory is starting to fill up. Act now to stay ahead.")
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var healthyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            Text("Memory looks healthy — no action needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Memory summary

    private func memorySummary(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: min(s.usedRatio, 1.0)) {
                HStack {
                    Text("Memory")
                    Spacer()
                    Text("\(Int(s.usedRatio * 100))% used")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .tint(s.pressure.color)

            HStack {
                stat("Used", format(s.usedMB))
                Spacer()
                stat("Free", format(s.freeMB))
                Spacer()
                stat("Swap", format(s.swapUsedMB))
            }
        }
    }

    // MARK: - Top apps

    private func topApps(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top memory users")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(s.topProcesses(5)) { proc in
                HStack {
                    Text(proc.name)
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(proc.rssMB)) MB")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
                .contextMenu {
                    if proc.bundleIdentifier != nil {
                        Button("Quit \(proc.name)") { onQuitApp(proc.pid) }
                        Button("Never suggest \(proc.name)") { onNeverSuggest(proc.name) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Open at login", isOn: Binding(
                get: { LoginItemManager.isEnabled },
                set: { LoginItemManager.set($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Quit MacShanti", action: onQuitSelf)
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }

    // MARK: - Helpers

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private func icon(for kind: Recommendation.Kind) -> String {
        switch kind {
        case .restart: return "arrow.clockwise.circle.fill"
        case .quit: return "xmark.circle.fill"
        case .closeSession: return "rectangle.stack.badge.minus"
        }
    }

    private func color(for kind: Recommendation.Kind) -> Color {
        switch kind {
        case .restart: return .orange
        case .quit: return .red
        case .closeSession: return .blue
        }
    }

    private func format(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}
