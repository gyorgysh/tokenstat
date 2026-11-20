// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// What the Home checklist knows and can do. Built by the root, which owns
/// the account and the machine models, so Home stays a view.
struct SetupHintsState {
    let signedIn: Bool
    let remoteAllowed: Bool
    let remoteOn: Bool
    let deviceCount: Int
    let onSignIn: () -> Void
    let onTurnOnRemote: () -> Void
    let onOpenDevices: () -> Void
    let onLoad: () async -> Void
}

/// Three steps on Home, the same three the website's dashboard walks:
/// an account, remote access, a second device.
///
/// Each step is done when its fact is true, not when somebody clicked it, so
/// the card reflects the machine rather than a history of taps. It hides
/// itself once everything is done, and "Hide" puts it away for good.
struct SetupHintsCard: View {
    let state: SetupHintsState
    @AppStorage("setupHints.hidden") private var hidden = false

    private enum Step: Int, CaseIterable { case account, remote, device }

    private func isDone(_ step: Step) -> Bool {
        switch step {
        case .account: state.signedIn
        case .remote: state.remoteOn
        case .device: state.deviceCount >= 2
        }
    }

    private var doneCount: Int { Step.allCases.filter(isDone).count }
    private var current: Step? { Step.allCases.first { !isDone($0) } }

    var body: some View {
        if !hidden, current != nil {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("apple.setuphints.title")).font(Theme.headline)
                        Text(L10n.text("apple.setuphints.progress", "\(doneCount)", "\(Step.allCases.count)"))
                            .font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Button { withAnimation(.easeOut(duration: 0.2)) { hidden = true } } label: {
                        ActionIcon.dismiss.label(L10n.text("apple.setuphints.hide"))
                    }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Step.allCases, id: \.self) { step in
                        row(step)
                        if step != Step.allCases.last {
                            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 34)
                        }
                    }
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
            .task { await state.onLoad() }
        }
    }

    private func row(_ step: Step) -> some View {
        let done = isDone(step)
        let now = step == current
        return HStack(alignment: .center, spacing: Theme.Space.m) {
            ZStack {
                Circle()
                    .fill(done ? Theme.accent : (now ? Theme.accentSoft : Color.clear))
                    .overlay(Circle().strokeBorder(done ? Color.clear : (now ? Theme.accent : Theme.border)))
                if done {
                    Image(systemName: "checkmark").font(Theme.font(10, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)").font(Theme.caption.weight(.semibold))
                        .foregroundStyle(now ? Theme.accent : Color.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(step)).font(Theme.callout.weight(.medium))
                    .foregroundStyle(done ? .secondary : .primary)
                if !done {
                    Text(detail(step)).font(Theme.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.s)
            if now { action(step) }
        }
        .padding(.vertical, Theme.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? L10n.text("apple.setuphints.done") : "")
    }

    private func title(_ step: Step) -> String {
        switch step {
        case .account: isDone(.account) ? L10n.text("apple.setuphints.account_done") : L10n.text("apple.setuphints.account")
        case .remote: isDone(.remote) ? L10n.text("apple.setuphints.remote_done") : L10n.text("apple.setuphints.remote")
        case .device: L10n.text("apple.setuphints.device")
        }
    }

    private func detail(_ step: Step) -> String {
        switch step {
        case .account: L10n.text("apple.setuphints.account_detail")
        case .remote: state.remoteAllowed || !state.signedIn
            ? L10n.text("apple.setuphints.remote_detail") : L10n.text("apple.setuptour.remote_plan")
        case .device: L10n.text("apple.setuphints.device_detail")
        }
    }

    @ViewBuilder
    private func action(_ step: Step) -> some View {
        switch step {
        case .account:
            Button(L10n.text("apple.setuptour.sign_in"), .signIn, action: state.onSignIn)
                .buttonStyle(AccentButtonStyle(small: true))
        case .remote:
            Button(L10n.text("apple.setuphints.turn_on"), .connect, action: state.onTurnOnRemote)
                .buttonStyle(AccentButtonStyle(small: true))
                .disabled(!state.remoteAllowed)
        case .device:
            Button(L10n.text("apple.setuphints.open_devices"), .device, action: state.onOpenDevices)
                .buttonStyle(SecondaryButtonStyle(small: true))
        }
    }
}
