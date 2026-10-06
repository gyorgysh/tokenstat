// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

@main
struct TokenstatWatchApp: App {
    @State private var model = TokenstatWatchModel.shared
    var body: some Scene {
        WindowGroup { TokenstatWatchRoot().environment(model).tint(Color("AccentColor")).task { model.activate() } }
            .backgroundTask(.watchConnectivity) { await TokenstatWatchModel.shared.handleBackgroundTransfer() }
    }
}

struct TokenstatWatchRoot: View {
    @Environment(TokenstatWatchModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var week = false
    private var accent: Color { Color("AccentColor") }
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            TabView(selection: $model.destination) {
                usage.tag(WatchScreen.usage)
                limits.tag(WatchScreen.limits)
                requests.tag(WatchScreen.requests)
            }.tabViewStyle(.verticalPage)
                .navigationTitle("tokenstat")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.refresh() } label: {
                            if model.refreshing { ProgressView().tint(.white) }
                            else { Image(systemName: "arrow.clockwise").foregroundStyle(accent) }
                        }.disabled(model.refreshing).accessibilityLabel("Refresh from iPhone")
                    }
                }
                .sheet(item: $model.selectedApproval) { approval in
                    TokenstatWatchApprovalView(approval: approval)
                }
        }
        .onOpenURL { url in
            guard url.scheme == "tokenstat", url.host == "watch", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return }
            if url.path == "/limits" { model.destination = .limits }
            else if url.path == "/requests" { model.destination = .requests }
        }
        .onChange(of: phase) { _, value in
            if value == .active { model.activate(); if model.destination == .requests { model.refresh() } }
        }
        .task(id: model.destination) {
            if model.destination == .projects { model.destination = .usage }
            if model.destination == .requests { model.refresh() }
        }
    }

    private func heading(_ title: String) -> some View {
        HStack(spacing: 7) {
            TokenstatWidgetMark(size: 19).foregroundStyle(accent)
            Text(title).font(.system(.headline, design: .rounded))
        }
    }

    private var usage: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    heading("Activity")
                    HStack(spacing: 6) {
                        periodButton("Today", selected: !week) { week = false }
                        periodButton("Week", selected: week) { week = true }
                    }
                    if let usage = model.snapshot.usage {
                        let value = week ? usage.weekTotal(at: context.date) : usage.today(at: context.date)?.value
                        Text(value.map(EcosystemUsage.displayMoney) ?? "—")
                            .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.55).contentTransition(.numericText())
                        Text("Value at list rates").font(.caption2).foregroundStyle(.secondary)
                        HStack(alignment: .bottom, spacing: 4) {
                            let days = usage.weekWindow(at: context.date)
                            let peak = max(1, days.filter { !$0.locked }.map(\.value).max() ?? 1)
                            ForEach(days) { day in
                                RoundedRectangle(cornerRadius: 3).fill(accent.gradient)
                                    .frame(height: max(3, CGFloat(day.locked ? 0 : day.value) / CGFloat(peak) * 42))
                                    .opacity(day.locked ? 0.15 : 1)
                            }
                        }.frame(height: 42).accessibilityHidden(true)
                        HStack { Text(week ? "Today" : "7 days"); Spacer()
                            Text((week ? usage.today(at: context.date)?.value : usage.weekTotal(at: context.date)).map(EcosystemUsage.displayMoney) ?? "—")
                                .monospacedDigit()
                        }.font(.caption)
                        Text(usage.scope).font(.caption2).foregroundStyle(.secondary)
                        Text(usage.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Open tokenstat on your iPhone to sync your activity.").font(.caption).foregroundStyle(.secondary)
                        Button("Sync from iPhone") { model.refresh() }.buttonStyle(.bordered).disabled(model.refreshing)
                    }
                    message
                }.frame(maxWidth: .infinity, alignment: .leading).privacySensitive()
            }
        }
    }

    private func periodButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.2), action) } label: {
            Text(title).font(.caption.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 36)
                .background(selected ? accent.opacity(0.24) : .white.opacity(0.07), in: Capsule())
                .foregroundStyle(selected ? accent : .primary)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var limits: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    heading("Plan limits")
                    if (model.snapshot.limits ?? []).isEmpty {
                        Text("Enable Share with my devices in Plan limits on your computer, then refresh on your iPhone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.snapshot.limits ?? []) { provider in
                        TokenstatLimitReadingView(provider: provider, date: context.date, accent: accent, maximumWindows: 8)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                    }
                    if model.omittedProviders > 0 { Text("More providers on your iPhone.").font(.caption2).foregroundStyle(.secondary) }
                    message
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var message: some View {
        if let message = model.message { Text(message).font(.caption2).foregroundStyle(.secondary) }
    }

    private var requests: some View {
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            List {
                heading("Requests").listRowBackground(Color.clear)
                if model.approvals.isEmpty {
                    Text("No pending requests. Refresh to check your connected computers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.approvals) { approval in
                    Button { model.selectedApproval = approval } label: {
                        HStack(alignment: .top, spacing: 8) {
                            TokenstatWidgetMark(size: 17).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(approval.verb).font(.headline).lineLimit(2)
                                Text(approval.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                Text(approval.preview).font(.caption2).lineLimit(2)
                            }
                        }
                    }.privacySensitive().listRowBackground(accent.opacity(0.10))
                }
                if model.omittedApprovals > 0 { Text("Review more requests on your iPhone.").font(.caption2).foregroundStyle(.secondary) }
                message
            }
        }
    }
}

struct TokenstatWatchApprovalView: View {
    let approval: EcosystemApproval
    @Environment(TokenstatWatchModel.self) private var model
    @State private var confirmAlways = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(approval.verb).font(.headline)
                    Text(approval.host).font(.caption2).foregroundStyle(.secondary)
                    Text(approval.preview).font(.system(.caption2, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                    if context.date >= approval.expiresAt {
                        Text("Request expired").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Expires \(approval.expiresAt, style: .relative)").font(.caption2).foregroundStyle(.secondary)
                        if approval.requiresPhoneReview {
                            Text("This request is too long to review here. Open it on your iPhone to allow it.").font(.caption2)
                        } else {
                            Button("Allow Once") { model.resolve(approval, choice: "allow") }
                                .buttonStyle(.borderedProminent)
                            if let scope = approval.alwaysAllowScope {
                                Text("Always Allow remembers “\(scope)” for this chat only.").font(.caption2).foregroundStyle(.secondary)
                                Button("Always Allow") { confirmAlways = true }.buttonStyle(.bordered)
                            }
                        }
                        Button("Deny", role: .destructive) { model.resolve(approval, choice: "deny") }.buttonStyle(.bordered)
                    }
                    if model.refreshing { ProgressView("Confirming with host…").font(.caption2) }
                    if let message = model.message { Text(message).font(.caption2).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.refreshing).privacySensitive()
            }.navigationTitle("Review request")
        }
        .confirmationDialog("Always allow for this chat?", isPresented: $confirmAlways, titleVisibility: .visible) {
            Button("Always Allow") { model.resolve(approval, choice: "allowAlways") }
        } message: {
            Text("The host will remember “\(approval.alwaysAllowScope ?? "")” for this chat only.")
        }
    }
}
