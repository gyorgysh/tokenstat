// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Remote access as the tour can drive it. Only a host has the switch: the
/// Mac passes one, a phone passes nil and is told where the switch lives.
struct SetupTourRemote {
    let allowed: Bool
    let enabled: Bool
    let set: (Bool) async -> Void
}

/// The host helper's lifetime, as the tour can drive it. Mac only.
struct SetupTourHost {
    let policy: HostPolicy?
    let saving: Bool
    let set: (Bool) async -> Void
    /// Plan limits shared with the account's other devices.
    let limitsShared: Bool
    let setLimitsShared: (Bool) async -> Void
}

/// A short, skippable pass over the choices that change how the app feels:
/// how it looks, and how it reaches your other machines.
///
/// Three steps, each one screen, each one optional. Nothing here is a
/// setting that lives only here: every control is the same one Settings has,
/// so skipping costs nothing and a choice made here shows up there.
struct SetupTour: View {
    let signedIn: Bool
    var remote: SetupTourRemote?
    /// Quick settings for this machine. A phone passes nil and skips the step.
    var host: SetupTourHost? = nil
    let onSignIn: () -> Void
    let onFinish: () -> Void

    private enum Step: Int, CaseIterable { case welcome, look, quick, connect }

    private var steps: [Step] { host == nil ? [.welcome, .look, .connect] : Step.allCases }
    private var position: Int { steps.firstIndex(of: step) ?? 0 }

    @State private var step = Step.welcome
    @AppStorage(SetupTourPreferences.disabledKey) private var disabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                Group {
                    switch step {
                    case .welcome: welcome
                    case .look: look
                    case .quick: quick
                    case .connect: connect
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.l)
                .id(step)
                .transition(.opacity)
            }
            footer
        }
        .background(Theme.background)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            Wordmark(size: 16, fills: false).fixedSize()
            Spacer()
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { item in
                    Capsule()
                        .fill((steps.firstIndex(of: item) ?? 0) <= position ? Theme.accent : Theme.border)
                        .frame(width: item == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("apple.setuptour.step_of", "\(position + 1)", "\(steps.count)"))
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.l)
    }

    /// One row on the Mac. On a phone the choice to stop showing it gets a
    /// row of its own and the two buttons share the width, because four
    /// things across a phone truncated both buttons to their icons.
    private var footer: some View {
        VStack(spacing: Theme.Space.s) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Group {
                if platformIsTouch {
                    VStack(spacing: Theme.Space.m) {
                        dontShow
                        HStack(spacing: Theme.Space.s) { buttons(filling: true) }
                    }
                } else {
                    HStack(spacing: Theme.Space.s) {
                        dontShow
                        Spacer(minLength: Theme.Space.s)
                        buttons(filling: false)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.l)
            .padding(.top, Theme.Space.xs)
        }
    }

    private var dontShow: some View {
        Toggle(L10n.text("apple.setuptour.dont_show_again"), isOn: $disabled)
            #if os(macOS)
            .toggleStyle(.checkbox)
            .fixedSize()
            #endif
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func buttons(filling: Bool) -> some View {
        let width: CGFloat? = filling ? .infinity : nil
        if step == .welcome {
            Button(action: onFinish) {
                ActionIcon.dismiss.label(L10n.text("apple.setuptour.skip")).frame(maxWidth: width)
            }
            .buttonStyle(SecondaryButtonStyle(comfortable: filling))
        } else {
            Button { move(-1) } label: {
                ActionIcon.back.label(L10n.text("common.back")).frame(maxWidth: width)
            }
            .buttonStyle(SecondaryButtonStyle(comfortable: filling))
        }
        if step == .connect {
            Button(action: onFinish) {
                ActionIcon.save.label(L10n.text("apple.setuptour.done")).frame(maxWidth: width)
            }
            .buttonStyle(AccentButtonStyle(comfortable: filling))
            .keyboardShortcut(.defaultAction)
        } else {
            Button { move(1) } label: {
                ActionIcon.next.label(L10n.text("apple.setuptour.next")).frame(maxWidth: width)
            }
            .buttonStyle(AccentButtonStyle(comfortable: filling))
            .keyboardShortcut(.defaultAction)
        }
    }

    private func move(_ delta: Int) {
        let next = position + delta
        if steps.indices.contains(next) { step = steps[next] }
    }

    private func heading(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.title2.weight(.semibold))
            Text(body).font(Theme.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            heading(L10n.text("apple.setuptour.welcome_title"), L10n.text("apple.setuptour.welcome_body"))
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                point("paintpalette", L10n.text("apple.setuptour.point_look"))
                point("dot.radiowaves.left.and.right", L10n.text("apple.setuptour.point_connect"))
                point("slider.horizontal.3", L10n.text("apple.setuptour.point_later"))
            }
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text).font(Theme.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var look: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            heading(L10n.text("apple.setuptour.look_title"), L10n.text("apple.setuptour.look_body"))
            AppearancePicker(comfortable: platformIsTouch)
            #if os(macOS)
            SetupTourGlass()
            #endif
        }
    }

    private var quick: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            heading(L10n.text("apple.setuptour.quick_title"), L10n.text("apple.setuptour.quick_body"))
            #if os(macOS)
            if let host {
                SetupTourQuickSettings(host: host)
            }
            #endif
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if !signedIn {
                heading(L10n.text("apple.setuptour.account_title"), L10n.text("apple.setuptour.account_body"))
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    point("chart.bar", L10n.text("apple.setuptour.benefit_usage"))
                    point("iphone.and.arrow.forward", L10n.text("apple.setuptour.benefit_remote"))
                    point("lock", L10n.text("apple.setuptour.benefit_private"))
                    point("gift", L10n.text("apple.setuptour.benefit_free"))
                }
                Button(L10n.text("apple.setuptour.sign_in"), .signIn, action: onSignIn)
                    .buttonStyle(AccentButtonStyle())
            } else if let remote {
                heading(L10n.text("apple.setuptour.remote_title"), L10n.text("apple.setuptour.remote_body"))
                Toggle(isOn: Binding(get: { remote.allowed && remote.enabled },
                                     set: { value in Task { await remote.set(value) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("apple.machinesview.enable_remote_access")).font(Theme.callout.weight(.semibold))
                        Text(remote.allowed ? L10n.text("apple.setuptour.remote_free") : L10n.text("apple.setuptour.remote_plan"))
                            .font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!remote.allowed)
                .padding(Theme.Space.m)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                Text(L10n.text("apple.machinesview.connections_are_end_to_end_encrypted_scree.fca19521"))
                    .font(Theme.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                heading(L10n.text("apple.setuptour.remote_phone_title"), L10n.text("apple.setuptour.remote_phone_body"))
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    point("1.circle", L10n.text("apple.setuptour.remote_phone_step1"))
                    point("2.circle", L10n.text("apple.setuptour.remote_phone_step2"))
                    point("3.circle", L10n.text("apple.setuptour.remote_phone_step3"))
                }
                Text(L10n.text("apple.setuptour.remote_free"))
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var platformIsTouch: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }
}

#if os(macOS)
/// The sidebar's glass, in the tour. The same stored values Appearance
/// settings write, so the two can never disagree.
private struct SetupTourGlass: View {
    @AppStorage(SidebarAppearancePreferences.enabledKey) private var enabled = true
    @AppStorage(SidebarAppearancePreferences.washKey) private var wash = SidebarAppearancePreferences.defaultWash

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Toggle(L10n.text("apple.sidebarappearance.glass"), isOn: $enabled)
                .toggleStyle(.switch)
                .font(Theme.callout)
            HStack {
                Text(L10n.text("apple.sidebarappearance.opacity"))
                Spacer()
                Text(SidebarAppearancePreferences.normalized(wash), format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(Theme.callout)
            Slider(value: Binding(get: { SidebarAppearancePreferences.normalized(wash) }, set: { wash = $0 }),
                   in: 0...1, step: 0.05)
                .tint(Theme.accent)
                .disabled(!enabled)
                .accessibilityLabel(L10n.text("apple.sidebarappearance.opacity"))
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}

/// The two switches that change the most at a glance: whether this Mac stays
/// reachable after quitting, and whether plan limits reach your phone. Both
/// write the same stored state Account settings shows.
private struct SetupTourQuickSettings: View {
    let host: SetupTourHost

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let policy = host.policy {
                row(symbol: "bolt.horizontal.circle",
                    title: L10n.text("apple.accountview.always_on_host.f7990642"),
                    detail: policy.alwaysOn
                        ? L10n.text("apple.accountview.the_host_helper_keeps_running_after_you_qu.8da69cf5")
                        : L10n.text("apple.accountview.the_host_helper_stops_when_you_quit_tokens.3285420e"),
                    note: policy.alwaysOn && policy.hasInternalBattery ? L10n.text("apple.accountview.uses_more_power.a24adb34") : nil,
                    isOn: Binding(get: { policy.alwaysOn }, set: { on in Task { await host.set(on) } }))
                    .disabled(host.saving)
            } else {
                Text(L10n.text("apple.accountview.the_host_helper_has_not_answered_yet.ed11e9fb"))
                    .font(Theme.callout).foregroundStyle(.secondary)
                    .padding(.vertical, Theme.Space.m)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            row(symbol: "gauge.with.dots.needle.33percent",
                title: L10n.text("apple.setuptour.limits_title"),
                detail: L10n.text("apple.accountview.shows_how_much_of_each_tool_s_subscription.0a16d097"),
                note: nil,
                isOn: Binding(get: { host.limitsShared }, set: { on in Task { await host.setLimitsShared(on) } }))
        }
        .padding(.horizontal, Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }

    private func row(symbol: String, title: String, detail: String, note: String?, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(Theme.font(15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.callout.weight(.semibold))
                Text(detail).font(Theme.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.Space.m)
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, Theme.Space.m)
    }
}
#endif
