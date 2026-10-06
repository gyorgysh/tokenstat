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
                        TokenstatWidgetMark(size: 20).frame(width: 20, height: 20).foregroundStyle(LiveWorkStyle.brand)
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
                TokenstatWidgetMark(size: 18, decorative: false).frame(width: 18, height: 18).foregroundStyle(LiveWorkStyle.brand)
                    .accessibilityLabel("tokenstat")
            } compactTrailing: {
                LiveWorkSymbol(phase: context.state.phase, stale: context.isStale).frame(width: 20)
            } minimal: {
                if context.state.phase == .working && !context.isStale {
                    TokenstatWidgetMark(size: 20, decorative: false).frame(width: 20, height: 20).foregroundStyle(LiveWorkStyle.brand)
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
    static let brand = Color(red: 0.64, green: 0.44, blue: 1)
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
        default: return brand
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
    var body: some View {
        Group {
            if state.phase.finished || dimmed || stale {
                let seconds = max(0, Int(state.updatedAt - attributes.startedAt))
                Text(seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                     : String(format: "%d:%02d", seconds / 60, seconds % 60))
            } else {
                Text(timerInterval: Date(timeIntervalSince1970: attributes.startedAt)...Date.distantFuture, countsDown: false, showsHours: false)
            }
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
    }
}

struct LiveWorkCard: View {
    var attributes: LiveWorkAttributes
    var state: LiveWorkAttributes.ContentState
    var stale = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 14) {
            TokenstatWidgetMark(size: 32).frame(width: 32, height: 32)
                .foregroundStyle(LiveWorkStyle.brand)
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
        }
        .foregroundStyle(.white).padding(18)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: state.phase)
        .environment(\.colorScheme, .dark)
    }
}
