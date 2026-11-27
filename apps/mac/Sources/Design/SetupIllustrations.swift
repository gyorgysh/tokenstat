// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

enum RoutingBehavior: String, CaseIterable, Identifiable, Hashable {
    case switchAgent
    case wait
    case switchAndReturn
    case ask

    var id: String { rawValue }

    init(_ policy: ChatRoutingPolicy) {
        if policy.enabled {
            self = policy.waitForReset || policy.returnPreferred ? .switchAndReturn : .switchAgent
        } else {
            self = policy.waitForReset ? .wait : .ask
        }
    }

    func apply(to policy: inout ChatRoutingPolicy) {
        policy.enabled = needsAgents
        policy.waitForReset = self == .wait || self == .switchAndReturn
        policy.returnPreferred = self == .switchAndReturn
    }

    var needsAgents: Bool { self == .switchAgent || self == .switchAndReturn }

    var title: String {
        switch self {
        case .switchAgent: L10n.text("common.chat_route_behavior_switch")
        case .wait: L10n.text("common.chat_route_behavior_wait")
        case .switchAndReturn: L10n.text("common.chat_route_behavior_return")
        case .ask: L10n.text("common.chat_route_behavior_ask")
        }
    }

    var detail: String {
        switch self {
        case .switchAgent: L10n.text("common.chat_route_behavior_switch_detail")
        case .wait: L10n.text("common.chat_route_behavior_wait_detail")
        case .switchAndReturn: L10n.text("common.chat_route_behavior_return_detail")
        case .ask: L10n.text("common.chat_route_behavior_ask_detail")
        }
    }

    var symbol: String {
        switch self {
        case .switchAgent: "arrow.right.circle"
        case .wait: "clock"
        case .switchAndReturn: "arrow.triangle.2.circlepath"
        case .ask: "hand.raised"
        }
    }

    func summary(agents: [String]) -> String {
        let list = agents.joined(separator: L10n.text("common.chat_route_then"))
        switch self {
        case .switchAgent: return L10n.text("common.chat_route_summary_switch", list)
        case .wait: return L10n.text("common.chat_route_summary_wait")
        case .switchAndReturn: return L10n.text("common.chat_route_summary_return", list)
        case .ask: return L10n.text("common.chat_route_summary_ask")
        }
    }
}

struct RoutingIllustration: View {
    var behavior: RoutingBehavior
    var height: CGFloat = 120
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0.62 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.2) / 4.2
            scene(phase)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(Theme.accentSoft.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }

    private func scene(_ t: Double) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let mid = geometry.size.height / 2 - 6
            let left = CGPoint(x: width * 0.26, y: mid)
            let right = CGPoint(x: width * 0.74, y: mid)
            let fill = min(t / 0.38, 1) * (behavior == .wait ? max(0, 1 - max(0, t - 0.78) / 0.16) : 1)
            let full = fill >= 0.999
            ZStack {
                if behavior.needsAgents {
                    path(from: left, to: right)
                        .stroke(Theme.accent.opacity(0.25), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5]))
                }
                agent(symbol: "sparkle", at: left, fill: fill, warn: full && behavior != .wait, active: activeLeft(t))
                if behavior.needsAgents {
                    agent(symbol: "circle.hexagongrid", at: right, fill: 0.15, warn: false, active: !activeLeft(t))
                    if let travel = traveller(t) {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 10, height: 10)
                            .shadow(color: Theme.accent.opacity(0.6), radius: 6)
                            .position(point(on: travel.forward ? (left, right) : (right, left), at: travel.progress))
                    }
                } else {
                    badge(at: right, t: t)
                }
            }
        }
    }

    private func activeLeft(_ t: Double) -> Bool {
        switch behavior {
        case .switchAgent: t < 0.62
        case .switchAndReturn: t < 0.6 || t > 0.9
        default: true
        }
    }

    private func traveller(_ t: Double) -> (forward: Bool, progress: Double)? {
        if t >= 0.42, t < 0.62 { return (true, ease((t - 0.42) / 0.2)) }
        if behavior == .switchAndReturn, t >= 0.74, t < 0.9 { return (false, ease((t - 0.74) / 0.16)) }
        return nil
    }

    private func ease(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }

    private func point(on line: (CGPoint, CGPoint), at progress: Double) -> CGPoint {
        let lift = sin(progress * .pi) * -18
        return CGPoint(x: line.0.x + (line.1.x - line.0.x) * progress,
                       y: line.0.y + (line.1.y - line.0.y) * progress + lift)
    }

    private func path(from a: CGPoint, to b: CGPoint) -> Path {
        Path { path in
            path.move(to: a)
            path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: a.y - 36))
        }
    }

    private func agent(symbol: String, at point: CGPoint, fill: Double, warn: Bool, active: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(Theme.font(18, weight: .semibold))
                .foregroundStyle(active ? Color.white : Theme.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(active ? Theme.accent : Theme.panel))
                .overlay(Circle().strokeBorder(Theme.accent.opacity(active ? 0 : 0.35), lineWidth: 1))
                .scaleEffect(active ? 1.06 : 0.94)
            Capsule()
                .fill(Theme.border)
                .frame(width: 46, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(warn ? Theme.danger : Theme.accent).frame(width: 46 * fill, height: 5)
                }
        }
        .position(x: point.x, y: point.y + 8)
        .animation(.easeInOut(duration: 0.25), value: active)
    }

    @ViewBuilder
    private func badge(at point: CGPoint, t: Double) -> some View {
        let shown = t > 0.4
        Image(systemName: behavior == .wait ? "clock" : "hand.raised.fill")
            .font(Theme.font(22, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .rotationEffect(.degrees(behavior == .wait ? (t - 0.4) * 540 : 0))
            .frame(width: 52, height: 52)
            .background(Circle().fill(Theme.panel))
            .overlay(Circle().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
            .scaleEffect(shown ? 1 + (behavior == .ask ? sin(t * .pi * 6) * 0.05 : 0) : 0.6)
            .opacity(shown ? 1 : 0.25)
            .position(x: point.x, y: point.y + 8)
    }
}

struct ProfilesIllustration: View {
    var height: CGFloat = 130
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0.2 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6
            let work = t < 0.5
            HStack(spacing: Theme.Space.m) {
                card(L10n.text("common.profiles.guide_work"), symbol: "briefcase.fill",
                     detail: L10n.text("common.profiles.guide_work_detail"), selected: work)
                Image(systemName: "arrow.left.arrow.right")
                    .font(Theme.font(15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .rotationEffect(.degrees(work ? 0 : 180))
                card(L10n.text("common.profiles.guide_personal"), symbol: "house.fill",
                     detail: L10n.text("common.profiles.guide_personal_detail"), selected: !work)
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: work)
            .padding(Theme.Space.m)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(Theme.accentSoft.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }

    private func card(_ title: String, symbol: String, detail: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Theme.accent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(selected ? Theme.accent : Theme.accentSoft))
                Text(title).font(Theme.callout.weight(.semibold))
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                }
            }
            Text(detail).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 4) {
                ForEach(["claude_code", "codex", "grok"], id: \.self) { id in
                    HarnessMark(id: id, size: 16).opacity(selected ? 1 : 0.45)
                }
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
        .scaleEffect(selected ? 1 : 0.96)
    }
}

struct SetupStepDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { step in
                Capsule()
                    .fill(step <= index ? Theme.accent : Theme.border)
                    .frame(width: step == index ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: index)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("common.setup_step", "\(index + 1)", "\(count)"))
    }
}

struct SetupChoiceCard: View {
    let symbol: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(Theme.font(15, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(selected ? Theme.accent : Theme.accentSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.callout.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(Theme.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(Theme.font(16, weight: .regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.border)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accentSoft : Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
