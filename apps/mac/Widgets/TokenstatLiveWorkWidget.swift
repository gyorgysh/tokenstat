// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(iOS)
import ActivityKit
#endif
import SwiftUI
import WidgetKit

#if os(iOS)

struct TokenstatLiveWorkWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveWorkAttributes.self) { context in
            LiveWorkCard(attributes: context.attributes, state: context.state, stale: context.isStale || context.state.computersOffline)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: context.isStale ? context.attributes.route : context.attributes.preferredRoute(for: context.state)))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        TokenstatWidgetMark(size: 20, fullColor: true).frame(width: 20, height: 20)
                        Text("tokenstat").font(.caption.weight(.semibold))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveWorkStatus(phase: context.state.phase, stale: context.isStale || context.state.computersOffline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let overview = context.state.overview {
                        LiveWorkOverviewBody(attributes: context.attributes, overview: overview, stale: context.isStale || context.state.computersOffline)
                            .padding(.top, 3)
                    } else { VStack(alignment: .leading, spacing: 8) {
                        Text(context.attributes.projectName).font(.headline).lineLimit(1).privacySensitive()
                        HStack {
                            Text(LiveWorkStyle.detail(context.state.phase, stale: context.isStale || context.state.computersOffline)).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            LiveWorkElapsed(attributes: context.attributes, state: context.state, stale: context.isStale || context.state.computersOffline)
                        }
                    }.padding(.top, 3) }
                }
            } compactLeading: {
                TokenstatWidgetMark(size: 18, decorative: false, fullColor: true).frame(width: 18, height: 18)
                    .accessibilityLabel("tokenstat")
            } compactTrailing: {
                if let overview = context.state.overview, !(context.isStale || context.state.computersOffline) {
                    Text("\(overview.waiting > 0 ? overview.waiting : overview.working > 0 ? overview.working : overview.total)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(overview.waiting > 0 ? .orange : .white)
                        .accessibilityLabel("\(overview.waiting > 0 ? overview.waiting : overview.working > 0 ? overview.working : overview.total) \(overview.waiting > 0 ? "waiting" : overview.working > 0 ? "working" : "sessions")")
                } else { LiveWorkSymbol(phase: context.state.phase, stale: context.isStale || context.state.computersOffline).frame(width: 20) }
            } minimal: {
                if context.state.phase == .working && !(context.isStale || context.state.computersOffline) {
                    TokenstatWidgetMark(size: 20, decorative: false, fullColor: true).frame(width: 20, height: 20)
                        .accessibilityLabel("tokenstat working")
                } else {
                    LiveWorkSymbol(phase: context.state.phase, stale: context.isStale || context.state.computersOffline)
                }
            }
            .widgetURL(URL(string: context.isStale ? context.attributes.route : context.attributes.preferredRoute(for: context.state)))
            .keylineTint(LiveWorkStyle.brand)
        }
    }
}

#endif

enum LiveWorkStyle {
    // The middle bar of the existing app logo, used for the activity's keyline.
    static let brand = Color(red: 0x6A / 255, green: 0x3D / 255, blue: 0xFF / 255)
    static func title(_ phase: LiveWorkPhase, stale: Bool) -> String {
        stale && !phase.finished ? "Reconnecting" : phase.title
    }
    static func detail(_ phase: LiveWorkPhase, stale: Bool) -> String {
        if stale && !phase.finished { return "Waiting for your computer" }
        switch phase {
        case .working: return "Your computer is working"
        case .waiting: return "Open to review"
        case .idle: return "Ready when you are"
        case .done: return "Ready to pick up"
        case .failed: return "Open to review the run"
        case .stopped: return "Work paused"
        }
    }
    static func symbol(_ phase: LiveWorkPhase, stale: Bool) -> String {
        if stale && !phase.finished { return "wifi.exclamationmark" }
        switch phase {
        case .working: return "ellipsis"
        case .waiting: return "hand.raised.fill"
        case .idle: return "pause.fill"
        case .done: return "checkmark"
        case .failed: return "exclamationmark"
        case .stopped: return "stop.fill"
        }
    }
    static func color(_ phase: LiveWorkPhase, stale: Bool) -> Color {
        if stale && !phase.finished { return .secondary }
        switch phase {
        case .waiting, .failed: return .orange
        case .done: return .mint
        default: return .white
        }
    }
}

struct LiveWorkSymbol: View {
    var phase: LiveWorkPhase
    var stale = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: LiveWorkStyle.symbol(phase, stale: stale))
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(LiveWorkStyle.color(phase, stale: stale))
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: phase)
            .accessibilityLabel(LiveWorkStyle.title(phase, stale: stale))
    }
}

struct LiveWorkStatus: View {
    var phase: LiveWorkPhase
    var stale = false
    var body: some View {
        HStack(spacing: 6) {
            LiveWorkSymbol(phase: phase, stale: stale)
            Text(LiveWorkStyle.title(phase, stale: stale)).font(.caption.weight(.semibold)).lineLimit(1)
        }.foregroundStyle(LiveWorkStyle.color(phase, stale: stale))
    }
}

struct LiveWorkElapsed: View {
    var attributes: LiveWorkAttributes
    var state: LiveWorkAttributes.ContentState
    var stale = false
    @Environment(\.isLuminanceReduced) private var dimmed
    @ScaledMetric(relativeTo: .caption) private var elapsedWidth: CGFloat = 76
    var body: some View {
        Group {
            if state.phase.finished || dimmed || stale {
                let seconds = max(0, Int(state.updatedAt - attributes.startedAt))
                Text(seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                     : String(format: "%d:%02d", seconds / 60, seconds % 60))
            } else {
                Text(Date(timeIntervalSince1970: attributes.startedAt), style: .timer)
            }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        // WidgetKit archives timer text as a horizontally flexible view; it
        // cannot remeasure as the digits change. Give it a finite layout slot.
        .multilineTextAlignment(.trailing)
        .frame(width: elapsedWidth, alignment: .trailing)
    }
}

struct LiveWorkCard: View {
    var attributes: LiveWorkAttributes
    var state: LiveWorkAttributes.ContentState
    var stale = false
    var interactive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        Group {
            if let overview = state.overview {
                LiveWorkOverviewCard(attributes: attributes, overview: overview, stale: stale, interactive: interactive)
            } else if textSize.isAccessibilitySize {
                // The Lock Screen caps Live Activity height. Give each reading
                // its own row so a large timer cannot displace the project.
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        TokenstatWidgetMark(size: 24, fullColor: true)
                        Text(attributes.projectName).font(.headline).lineLimit(1).privacySensitive()
                    }
                    LiveWorkStatus(phase: state.phase, stale: stale)
                    LiveWorkElapsed(attributes: attributes, state: state, stale: stale)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(14)
            } else {
                HStack(spacing: 14) {
                    TokenstatWidgetMark(size: 32, decorative: false, fullColor: true).frame(width: 32, height: 32)
                        .padding(13)
                        .background(LiveWorkStyle.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityLabel("tokenstat")
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 10) {
                            Text(attributes.projectName).font(.headline).lineLimit(1).privacySensitive()
                            Spacer(minLength: 0)
                            LiveWorkElapsed(attributes: attributes, state: state, stale: stale)
                        }
                        LiveWorkStatus(phase: state.phase, stale: stale)
                        Text(LiveWorkStyle.detail(state.phase, stale: stale)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(18)
            }
        }
        .foregroundStyle(.white)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: state.phase)
        .environment(\.colorScheme, .dark)
    }
}

struct LiveWorkOverviewCard: View {
    var attributes: LiveWorkAttributes
    var overview: LiveWorkOverview
    var stale = false
    var interactive = true
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TokenstatWidgetMark(size: 20, fullColor: true).frame(width: 20, height: 20)
                Text("Your work").font(.headline).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if textSize.isAccessibilitySize {
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer").font(.system(size: 12))
                        Text("\(overview.computers)").font(.caption2.monospacedDigit())
                    }.foregroundStyle(.secondary)
                        .accessibilityElement(children: .ignore).accessibilityLabel("\(overview.computers) computers")
                } else {
                    Text(overview.computers == 1 ? "1 computer" : "\(overview.computers) computers")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            LiveWorkOverviewBody(attributes: attributes, overview: overview, stale: stale, interactive: interactive)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

struct LiveWorkOverviewBody: View {
    var attributes: LiveWorkAttributes
    var overview: LiveWorkOverview
    var stale = false
    var interactive = true
    @Environment(\.dynamicTypeSize) private var textSize
    private var visible: [LiveWorkOverviewItem] {
        Array(overview.items.prefix(textSize.isAccessibilitySize ? 1 : textSize >= .xxLarge ? 2 : 3))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if stale {
                Label("Reconnecting to your computers", systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                ViewThatFits(in: .horizontal) {
                    counts(abbreviated: false)
                    counts(abbreviated: true)
                }
            }
            if visible.isEmpty {
                Text(stale || overview.offline > 0 ? "Open to reconnect" : "No active sessions")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            } else {
                ForEach(visible, id: \.key) { item in
                    if let hint = attributes.overviewHints?[item.key] {
                        if interactive, let url = URL(string: hint.route) {
                            Link(destination: url) { row(item, name: hint.name) }
                        } else { row(item, name: hint.name) }
                    } else {
                        row(item, name: item.kind == .chat ? "Chat" : "Terminal")
                    }
                }
            }
            let remaining = max(0, overview.total - visible.count)
            if overview.offline > 0 || remaining > 0 {
                HStack(spacing: 5) {
                    if remaining > 0 { Text("+\(remaining) more").font(.caption2) }
                    Spacer(minLength: 4)
                    if overview.offline > 0 { Label("\(overview.offline) offline", systemImage: "wifi.slash").font(.caption2) }
                }.foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func counts(abbreviated: Bool) -> some View {
        HStack(spacing: 12) {
            count(overview.working, label: "working", symbol: "ellipsis", color: .white, abbreviated: abbreviated)
            count(overview.waiting, label: "waiting", symbol: "hand.raised.fill", color: overview.waiting > 0 ? .orange : .secondary, abbreviated: abbreviated)
            count(overview.idle + overview.done, label: "idle", symbol: "pause.fill", color: .secondary, abbreviated: abbreviated)
            if overview.failed > 0 {
                count(overview.failed, label: "failed", symbol: "exclamationmark.circle", color: .orange, abbreviated: abbreviated)
            }
        }.font(.caption.monospacedDigit())
    }

    private func count(_ value: Int, label: String, symbol: String, color: Color, abbreviated: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            Text(abbreviated ? "\(value)" : "\(value) \(label)")
        }.foregroundStyle(color).accessibilityElement(children: .ignore).accessibilityLabel("\(value) \(label)")
    }

    private func row(_ item: LiveWorkOverviewItem, name: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: item.kind == .chat ? "bubble.left" : "terminal")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 14).accessibilityHidden(true)
            Text(name).font(.caption.weight(.medium)).lineLimit(1).privacySensitive()
            Spacer(minLength: 4)
            Text(stale ? "Unknown" : item.phase == .waiting ? "Needs you" : item.phase.title)
                .font(.caption2.weight(.semibold)).lineLimit(1)
                .foregroundStyle(stale ? .secondary : LiveWorkStyle.color(item.phase, stale: false))
        }
        .frame(minHeight: 20).foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}
