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
            LiveWorkCard(attributes: context.attributes, state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: context.attributes.route))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        TokenstatWidgetMark(size: 20, fullColor: true).frame(width: 20, height: 20)
                        Text("tokenstat").font(.caption.weight(.semibold))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveWorkStatus(phase: context.state.phase, stale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.attributes.projectName).font(.headline).lineLimit(1).privacySensitive()
                        HStack {
                            Text(LiveWorkStyle.detail(context.state.phase, stale: context.isStale)).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            LiveWorkElapsed(attributes: context.attributes, state: context.state, stale: context.isStale)
                        }
                    }.padding(.top, 3)
                }
            } compactLeading: {
                TokenstatWidgetMark(size: 18, decorative: false, fullColor: true).frame(width: 18, height: 18)
                    .accessibilityLabel("tokenstat")
            } compactTrailing: {
                LiveWorkSymbol(phase: context.state.phase, stale: context.isStale).frame(width: 20)
            } minimal: {
                if context.state.phase == .working && !context.isStale {
                    TokenstatWidgetMark(size: 20, decorative: false, fullColor: true).frame(width: 20, height: 20)
                        .accessibilityLabel("tokenstat working")
                } else {
                    LiveWorkSymbol(phase: context.state.phase, stale: context.isStale)
                }
            }
            .widgetURL(URL(string: context.attributes.route))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        Group {
            if textSize.isAccessibilitySize {
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
