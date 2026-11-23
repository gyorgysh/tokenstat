// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI

/// Rating and feedback, opened by hand from Settings.
///
/// Never shown on its own. The automatic ask is the system's rating sheet
/// (`ClientRootView`), because App Review allows no custom prompt for
/// ratings. This sheet only exists because somebody tapped Rate tokenstat,
/// and it offers both ways out on equal terms: a rating on the App Store
/// page, or a note to us. Neither depends on what the person thinks of the
/// app, so nothing here filters who gets sent to the store.
///
/// Either choice stops the automatic ask for good. Somebody who went to the
/// store page or wrote to us has answered, and asking again every two weeks
/// would only be noise. "Don't ask me again" does the same without leaving.
struct ClientReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsFeedback = false
    @State private var stoppedAsking = ClientReviewPrompt.isStopped()

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                ClientReviewGem(accent: Theme.accent, secondary: Theme.secondary, reduceMotion: reduceMotion)
                    .frame(width: 300, height: 220)
                    .accessibilityHidden(true)
                    .padding(.top, Theme.Space.m)
                VStack(spacing: Theme.Space.s) {
                    Text(L10n.text("apple.review.title"))
                        .font(Theme.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(L10n.text("apple.review.body"))
                        .font(ClientType.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.Space.l)
                VStack(spacing: Theme.Space.s) {
                    Button {
                        ClientReviewPrompt.stop()
                        dismiss()
                        openURL(ClientReviewPrompt.writeReviewURL)
                    } label: {
                        ActionIcon.appStore.label(L10n.text("apple.review.rate")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AccentButtonStyle(comfortable: true))
                    Button {
                        ClientReviewPrompt.stop()
                        showsFeedback = true
                    } label: {
                        ActionIcon.comment.label(L10n.text("apple.review.feedback")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
                    HStack(spacing: Theme.Space.s) {
                        Button {
                            dismiss()
                        } label: {
                            ActionIcon.done.label(L10n.text("apple.review.close")).frame(maxWidth: .infinity)
                        }
                        if !stoppedAsking {
                            Button {
                                ClientReviewPrompt.stop()
                                stoppedAsking = true
                                dismiss()
                            } label: {
                                ActionIcon.deny.label(L10n.text("apple.review.never")).frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(ClientType.label)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    if stoppedAsking {
                        Text(L10n.text("apple.review.stopped"))
                            .font(ClientType.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, Theme.Space.l)
            }
            .padding(.bottom, Theme.Space.l)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showsFeedback, onDismiss: { dismiss() }) {
            ClientWebBrowser(url: ClientWebPages.contact())
        }
    }
}
#endif
