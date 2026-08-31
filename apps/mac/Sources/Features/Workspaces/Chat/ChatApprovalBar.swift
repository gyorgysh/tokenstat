// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// A pinned reminder that a turn is waiting on you, sitting where the composer
/// would be.
///
/// The card in the transcript is the right place to *answer* a request, and it
/// is a poor place to *notice* one: a streaming reply pushes it up the page,
/// and by the time you look back the agent has been parked for a minute with
/// nothing on screen saying so. That is half of why the gate read as "nothing
/// ever appears" even once it worked.
///
/// So the composer is replaced, not merely decorated. There is nothing useful
/// to type while a turn is blocked, and taking the field away is the clearest
/// possible statement of what the conversation is waiting for. Pressing an
/// answer here settles the same request as the card, through the same call.
struct ChatApprovalBar: View {
    let approvals: [ChatApproval]
    let resolve: (ChatApproval, String) -> Void
    /// Jump the transcript to the card, for the times the preview alone is not
    /// enough to decide with.
    var showInTranscript: (ChatApproval) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let approval = approvals.first {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(
                            .pulse,
                            options: reduceMotion ? .nonRepeating : .repeating,
                            value: approval.id
                        )
                    Text(waitingTitle)
                        .font(Theme.callout.weight(.semibold))
                    Spacer(minLength: Theme.Space.s)
                    Button("Show in conversation", .reveal) { showInTranscript(approval) }
                        .buttonStyle(.plain)
                        .font(Theme.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .labelStyle(.titleOnly)
                }
                HStack(spacing: Theme.Space.s) {
                    Text(approval.verb)
                        .font(Theme.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.accentSoft, in: Capsule())
                    Text(approval.preview)
                        .font(Theme.monoText(11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                ChatApprovalActions(approval: approval, resolve: resolve)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.5)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.m)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(waitingTitle)
        }
    }

    /// Say how many are queued. An agent can ask twice before anybody looks,
    /// and answering one while a second is hidden behind it is confusing in a
    /// way a count fixes for free.
    private var waitingTitle: String {
        approvals.count > 1
            ? "Waiting for you · \(approvals.count) requests"
            : "Waiting for you"
    }
}
