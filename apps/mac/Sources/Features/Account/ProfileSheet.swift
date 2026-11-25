// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The profile window, behind the name in Account: the address, who can open
/// it, and the way to see it. An account with no handle starts on choosing
/// one, and the one-time offer is this same window.
struct ProfileSheet: View {
    enum Purpose { case settings, offer }

    let purpose: Purpose
    let model: AccountModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var picker: HandlePicker
    @State private var editing: Bool
    @State private var saving = false
    @State private var confirmingPublish = false
    @State private var error: String?
    @State private var copied = false
    #if os(iOS)
    @State private var webURL: URL?
    #endif

    init(purpose: Purpose, model: AccountModel) {
        self.purpose = purpose
        self.model = model
        _picker = State(initialValue: Self.makePicker(model.account?.handle))
        _editing = State(initialValue: (model.account?.handle ?? "").isEmpty)
    }

    private static func makePicker(_ current: String?) -> HandlePicker {
        HandlePicker(current: current) { try await Bridge.checkHandle($0) }
    }

    private var account: Account? { model.account }
    private var host: String { account?.host ?? "" }
    private var handle: String? { account?.handle.flatMap { $0.isEmpty ? nil : $0 } }
    private var isPublic: Bool { account?.profile?.isPublic ?? account?.profilePublic ?? false }
    private var url: URL? { handle.flatMap { URL(string: "\(host)/\($0)") } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Theme.Space.l) {
                    plate
                    Group {
                        if editing { editor } else { settings }
                    }
                    .padding(.horizontal, Theme.Space.l)
                }
                .padding(.bottom, Theme.Space.l)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .background(Theme.background)
        .overlay(alignment: .topTrailing) {
            InspectorCloseButton(action: { if !saving { dismiss() } }, help: L10n.text("common.close"),
                                 label: L10n.text("common.close"))
                .padding(Theme.Space.m)
        }
        .modalFrame(width: 440, height: 640)
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .sheet(isPresented: Binding(get: { webURL != nil }, set: { if !$0 { webURL = nil } })) {
            if let webURL { ClientWebBrowser(url: webURL) }
        }
        #endif
        .interactiveDismissDisabled(saving)
        .animation(Motion.unless(reduceMotion, Motion.morph), value: editing)
        .animation(Motion.unless(reduceMotion, Motion.morph), value: isPublic)
        .alert(L10n.text("common.profile.publish_title"), isPresented: $confirmingPublish) {
            Button(L10n.text("common.cancel"), role: .cancel) {}
            Button(L10n.text("common.profile.make_public")) { save { try await model.setProfile(public: true) } }
        } message: {
            Text(L10n.text("common.profile.public_detail"))
        }
        .onChange(of: model.signedIn) { _, signedIn in if !signedIn { dismiss() } }
    }

    private var plate: some View {
        let typed = editing ? picker.handle : ""
        let shown = typed.isEmpty ? (handle ?? L10n.text("common.handle.placeholder")) : typed
        return ProfilePlate(
            avatar: account?.avatar,
            name: account?.displayName.flatMap { $0.isEmpty ? nil : $0 }
                ?? (typed.isEmpty ? handle ?? L10n.text("common.profile.title") : typed),
            handle: handle,
            address: HandleRules.address(host: host, handle: shown),
            isExample: typed.isEmpty && handle == nil,
            isPublic: isPublic,
            copy: editing || handle == nil ? nil : copyAddress,
            copied: copied
        )
    }

    // MARK: Settings

    private var settings: some View {
        VStack(spacing: Theme.Space.l) {
            handleRow.modifier(ProfileCardSurface())
            if let profile = account?.profile {
                choices(profile)
                if profile.isPublic {
                    Toggle(L10n.text("common.profile.indexable"), isOn: Binding(
                        get: { profile.indexable },
                        set: { wanted in save { try await model.setProfile(indexable: wanted) } }
                    ))
                    .toggleStyle(.brandCheckbox)
                    .font(Theme.callout)
                    .frame(maxWidth: .infinity, minHeight: touch ? 44 : nil, alignment: .leading)
                    .padding(.leading, 4)
                    .disabled(saving)
                }
            }
            if isPublic, let url { viewButton(url) }
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Both answers, always in view, with the current one checked. Going back
    /// is the same tap as going there.
    private func choices(_ profile: AccountProfile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("common.profile.who_can_open"))
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                choice(icon: .security, title: L10n.text("common.profile.private"),
                       detail: L10n.text("common.profile.private_detail"), selected: !profile.isPublic) {
                    save { try await model.setProfile(public: false) }
                }
                ThemeRule().padding(.leading, 58)
                choice(icon: .browser, title: L10n.text("common.profile.public"),
                       detail: L10n.text("common.profile.public_detail"), selected: profile.isPublic) {
                    // Going public shows things to strangers, so it is asked
                    // once more. Going private is not.
                    confirmingPublish = true
                }
            }
            .modifier(ProfileCardSurface())
            .accessibilityElement(children: .contain)
        }
    }

    private func choice(icon: ActionIcon, title: String, detail: String, selected: Bool,
                        select: @escaping () -> Void) -> some View {
        Button { if !selected, !saving { select() } } label: {
            rowLabel(icon: icon, title: title, detail: detail) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(Theme.font(18, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(RowFeedbackStyle(bleed: 0, radius: 0))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func viewButton(_ url: URL) -> some View {
        Button { view(url) } label: {
            ActionIcon.external.label(L10n.text("common.profile.view")).frame(maxWidth: .infinity)
        }
        .buttonStyle(AccentButtonStyle(comfortable: touch))
    }

    @ViewBuilder
    private var handleRow: some View {
        let days = account?.profile?.handleChangeDays ?? 0
        let canChange = account?.profile != nil && days == 0
        let locked: String? = days == 0 ? nil : days == 1
            ? L10n.text("common.handle.change_tomorrow") : L10n.text("common.handle.change_in_days", "\(days)")
        if canChange {
            Button(action: startEditing) {
                rowLabel(icon: .edit, title: "@\(handle ?? "")", detail: L10n.text("common.handle.change_title")) { RowChevron() }
            }
            .buttonStyle(RowFeedbackStyle(bleed: 0, radius: 0))
        } else {
            rowLabel(icon: .profile, title: "@\(handle ?? "")", detail: locked) { EmptyView() }
                .accessibilityElement(children: .combine)
        }
    }

    private func rowLabel<Trailing: View>(icon: ActionIcon, title: String, detail: String?,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Theme.Space.m) {
            ActionSeat(icon: icon, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.callout.weight(.medium)).foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(Theme.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: Theme.Space.s)
            trailing()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    // MARK: Choosing a handle

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(handle == nil ? L10n.text("common.handle.claim_title") : L10n.text("common.handle.change_title"))
                    .font(Theme.title3.weight(.semibold))
                Text(handle == nil ? L10n.text("common.handle.claim_note") : L10n.text("common.handle.change_note"))
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HandleField(picker: picker, host: host, disabled: saving, onSubmit: claim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if editing {
            bar {
                Button(leaveTitle, .dismiss, action: leaveEditor)
                    .buttonStyle(SecondaryButtonStyle(comfortable: touch))
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Spacer()
                Button(handle == nil ? L10n.text("common.handle.claim") : L10n.text("common.save"),
                       handle == nil ? .claim : .save, action: claim)
                    .buttonStyle(AccentButtonStyle(comfortable: touch))
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || !picker.canClaim)
                    .accessibilityIdentifier("handle.claim")
            }
        }
    }

    private var leaveTitle: String {
        if handle != nil { return L10n.text("common.cancel") }
        return purpose == .offer ? L10n.text("common.skip") : L10n.text("common.close")
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            ThemeRule()
            HStack(spacing: Theme.Space.s, content: content)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
        }
    }

    private var touch: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    // MARK: Actions

    private func startEditing() {
        error = nil
        picker = Self.makePicker(handle)
        editing = true
    }

    private func leaveEditor() {
        if handle == nil { dismiss() } else { editing = false }
    }

    private func claim() {
        guard !saving, picker.canClaim else { return }
        let wanted = picker.handle
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.claimHandle(wanted)
                editing = false
            } catch is CancellationError {
                dismiss()
            } catch {
                picker.refuse(Self.words(error))
            }
        }
    }

    private func save(_ change: @escaping @MainActor () async throws -> Void) {
        guard !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do { try await change() }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }

    private func view(_ url: URL) {
        #if os(macOS)
        openURL(url)
        #else
        if let handle { webURL = ClientWebPages.publicProfile(host: host, handle: handle) }
        #endif
    }

    private func copyAddress() {
        guard let url else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.string = url.absoluteString
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }

    private static func words(_ error: Error) -> String {
        guard let bridge = error as? BridgeError, case let .core(code, message) = bridge,
              code.hasPrefix("profile_") else { return error.localizedDescription }
        return HandleRules.message(String(code.dropFirst("profile_".count)), fallback: message)
    }
}

private struct ProfileCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content.background(Theme.panel, in: shape)
            .overlay(shape.strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(shape)
    }
}

/// The name in Account, which opens the profile window.
struct ProfileNameButton<Label: View>: View {
    let model: AccountModel
    let account: Account
    /// Takes the row's width and ends in a chevron, as in Account. Off where
    /// the name shares a row with other things, as on Home.
    var fills = true
    @ViewBuilder let label: () -> Label

    @State private var showing = false

    var body: some View {
        // Nothing to open against a server without these settings, for an
        // account that has no page either.
        if account.profile != nil || !(account.handle ?? "").isEmpty {
            Button { showing = true } label: {
                HStack(spacing: Theme.Space.m) {
                    label()
                    if fills {
                        Spacer(minLength: 0)
                        RowChevron()
                    }
                }
                .padding(.vertical, fills ? Theme.Space.s : 4)
                .contentShape(.rect)
            }
            .buttonStyle(RowFeedbackStyle(bleed: Theme.Space.s, radius: 12))
            .help(L10n.text("common.profile.open_hint"))
            .accessibilityHint(L10n.text("common.profile.open_hint"))
            .accessibilityIdentifier("account.profile")
            .sheet(isPresented: $showing) { ProfileSheet(purpose: .settings, model: model) }
        } else if fills {
            label().frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: Theme.Space.m) { label() }
        }
    }
}

/// The line under the name: the handle and whether its page is public, or the
/// invitation to have one.
struct ProfileNameLine: View {
    let account: Account
    let font: Font

    var body: some View {
        if let handle = account.handle, !handle.isEmpty {
            HStack(spacing: 5) {
                Text("@\(handle)").foregroundStyle(.secondary)
                if let isPublic = account.profile?.isPublic ?? account.profilePublic {
                    Image(systemName: isPublic ? "globe" : "lock.fill")
                        .font(Theme.font(10, weight: .medium))
                        .foregroundStyle(isPublic ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                        .accessibilityLabel(isPublic ? L10n.text("common.profile.public") : L10n.text("common.profile.private"))
                }
            }
            .font(font)
        } else if account.profile != nil {
            Text(L10n.text("common.handle.claim_title")).font(font).foregroundStyle(Theme.accent)
        }
    }
}

/// Offers a handle once, to an account that has none, when Home is quiet.
///
/// "Once" is the account's: the answer is kept on the server, so skipping on a
/// phone is not asked again on the computer.
struct HandleOffer: ViewModifier {
    let model: AccountModel
    /// Home is in front with nothing over it.
    let ready: Bool
    @Binding var showing: Bool

    func body(content: Content) -> some View {
        content
            .task(id: ready && model.handleOfferDue) {
                guard ready, model.handleOfferDue else { return }
                // Behind the setup tour, which waits a little less.
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled, ready, model.handleOfferDue, model.beginHandleOffer() else { return }
                showing = true
            }
            // Closing it any way at all is an answer, including swiping it away.
            .sheet(isPresented: $showing, onDismiss: { Task { await model.answerHandleOffer() } }) {
                ProfileSheet(purpose: .offer, model: model)
            }
    }
}
