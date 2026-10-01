// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The in-app find bar: query, match count, previous/next, replace.
///
/// Neither AppKit's grey system bar nor a UIKit equivalent carries the
/// product Theme, so this sits above the buffer on every Apple client while
/// it is open. The query gets the full first row; the controls get a second
/// row of full-size targets, because four glyph buttons beside the field do
/// not fit a phone portrait. The buttons carry keyboard shortcuts, so
/// holding Command on an iPad discovers the same actions.
struct EditorFindBar: View {
    @Bindable var find: EditorFindSession
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                TextField(L10n.text("apple.editorfindbar.find_in_file.214c422e"), text: $find.query)
                    .textFieldStyle(.themed)
                    #if os(macOS)
                    .disableAutocorrection(true)
                    #else
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .focused($queryFocused)
                    .accessibilityLabel(L10n.text("apple.editorfindbar.find_in_file.214c422e"))
                    .onSubmit { find.goNext() }
                if let count = find.countLabel {
                    Text(count)
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.controlGlyph)
                        .accessibilityLabel(L10n.text("apple.editorfindbar.0_matches.498d34a5", "\(count)"))
                }
            }
            HStack(spacing: Theme.Space.xs) {
                Button {
                    find.goPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(minWidth: 44, minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.controlGlyph)
                .accessibilityLabel(L10n.text("apple.editorfindbar.previous_match.daa2f8c3"))
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!find.canNavigate)
                Button {
                    find.goNext()
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(minWidth: 44, minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.controlGlyph)
                .accessibilityLabel(L10n.text("apple.editorfindbar.next_match.825e5abd"))
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!find.canNavigate)
                Button(find.replacing ? L10n.text("apple.editorfindbar.hide_replace.7d07b712") : L10n.text("apple.editorfindbar.replace.95e15439")) { find.replacing.toggle() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .accessibilityLabel(find.replacing ? L10n.text("apple.editorfindbar.hide_replace.7d07b712") : L10n.text("apple.editorfindbar.show_replace.1ac21ac1"))
                Spacer(minLength: 0)
                Button {
                    find.showing = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.controlGlyph)
                .accessibilityLabel(L10n.text("apple.editorfindbar.close_find.eb903c9f"))
            }
            if find.replacing {
                TextField(L10n.text("apple.editorfindbar.replace_with.8382d317"), text: $find.replaceText)
                    .textFieldStyle(.themed)
                    #if os(macOS)
                    .disableAutocorrection(true)
                    #else
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .accessibilityLabel(L10n.text("apple.editorfindbar.replace_with.8382d317"))
                HStack(spacing: Theme.Space.s) {
                    Button(L10n.text("apple.editorfindbar.replace.95e15439")) { find.replaceCurrent() }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(!find.canReplace)
                    Button(L10n.text("apple.editorfindbar.replace_all.2ebcba96")) { find.replaceAll() }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(!find.canReplace)
                    if find.composing {
                        Text(L10n.text("apple.editorfindbar.finish_the_current_word_first.a438c4fc"))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.controlGlyph)
                    } else {
                        Text(L10n.text("apple.editorfindbar.replace_all_is_one_undo_in_this_file_only.f9398675"))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.controlGlyph)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(Theme.Space.s)
        .background(Theme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border)
        )
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.s)
        .onAppear { queryFocused = true }
    }
}
