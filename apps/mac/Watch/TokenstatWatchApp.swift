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
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            TabView(selection: $model.destination) {
                usage.tag(WatchScreen.usage)
                projects.tag(WatchScreen.projects)
                requests.tag(WatchScreen.requests)
            }.tabViewStyle(.verticalPage)
                .navigationTitle("tokenstat")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.refresh() } label: {
                            if model.refreshing { ProgressView().tint(.white) }
                            else { Image(systemName: "arrow.clockwise").foregroundStyle(.white) }
                        }.disabled(model.refreshing).accessibilityLabel("Refresh from iPhone")
                    }
                }
                .navigationDestination(item: $model.projectID) { id in
                    if let project = model.snapshot.projects.first(where: { $0.id == id }) {
                        ScrollView { VStack(spacing: 10) {
                            Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(Color("AccentColor"))
                            Text(project.name).font(.headline).multilineTextAlignment(.center)
                            Text(project.host).font(.caption).foregroundStyle(.secondary)
                            Text("Continue in tokenstat on your iPhone using Handoff.").font(.caption).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).privacySensitive() }
                            .userActivity("ai.tokenstat.open") { activity in
                                activity.title = "Open \(project.name) in tokenstat"
                                activity.userInfo = ["url": EcosystemRoute(screen: .workspaces, projectID: project.id, owner: model.snapshot.owner).url.absoluteString]
                                activity.isEligibleForHandoff = true
                            }
                    }
                }
                .sheet(item: $model.selectedApproval) { approval in
                    TokenstatWatchApprovalView(approval: approval)
                }
        }
        .onChange(of: phase) { _, value in
            if value == .active { model.activate(); if model.destination == .requests { model.refresh() } }
        }
        .task(id: model.destination) { if model.destination == .requests { model.refresh() } }
    }

    private var usage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let usage = model.snapshot.usage {
                    Text("TODAY").font(.caption2).foregroundStyle(.secondary)
                    Text(usage.today().map { EcosystemUsage.displayMoney($0.value) } ?? "—")
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.55).contentTransition(.numericText())
                    Text("Value at list rates · USD").font(.caption2).foregroundStyle(.secondary)
                    HStack(alignment: .bottom, spacing: 4) {
                        let week = usage.weekWindow()
                        let peak = max(1, week.filter { !$0.locked }.map(\.value).max() ?? 1)
                        ForEach(week) { day in
                            RoundedRectangle(cornerRadius: 3).fill(Color("AccentColor").gradient)
                                .frame(height: max(3, CGFloat(day.locked ? 0 : day.value) / CGFloat(peak) * 42))
                                .opacity(day.locked ? 0.15 : 1)
                        }
                    }.frame(height: 42).accessibilityHidden(true)
                    HStack { Text("7 days"); Spacer(); Text(usage.weekTotal().map(EcosystemUsage.displayMoney) ?? "—").monospacedDigit() }.font(.caption)
                    Label("\(usage.streak) day streak", systemImage: "flame.fill").font(.caption).foregroundStyle(Color("AccentColor"))
                    Text(usage.scope).font(.caption2).foregroundStyle(.secondary)
                    Text(usage.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your work, at a glance").font(.headline)
                        Text("Sync usage and projects from tokenstat on your iPhone.").font(.caption2).foregroundStyle(.secondary)
                        Button("Sync from iPhone") { model.refresh() }.font(.caption).buttonStyle(.bordered).disabled(model.refreshing)
                    }
                }
                if let message = model.message { Text(message).font(.caption2).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 2).privacySensitive()
        }
    }

    private var projects: some View {
        List {
            if model.snapshot.projects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Projects", systemImage: "folder.fill").font(.headline)
                    Text("Visit a project on your iPhone to keep it within reach here.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(model.snapshot.projects) { project in
                Button { model.projectID = project.id } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(project.name, systemImage: "folder.fill").font(.headline).lineLimit(2)
                        Text(project.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.privacySensitive()
            }
        }
    }

    private var requests: some View {
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            List {
                if model.approvals.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Requests", systemImage: "hand.raised.fill").font(.headline)
                        Text("Pending agent requests from your connected hosts appear here. Refresh to check.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(model.approvals) { approval in
                    Button { model.selectedApproval = approval } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(approval.verb).font(.headline).lineLimit(2)
                            Text(approval.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Text(approval.preview).font(.caption2).lineLimit(2)
                        }
                    }.privacySensitive()
                }
                if model.omittedApprovals > 0 {
                    Text("Review more requests on your iPhone.").font(.caption2).foregroundStyle(.secondary)
                }
                if let message = model.message { Text(message).font(.caption2).foregroundStyle(.secondary) }
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
