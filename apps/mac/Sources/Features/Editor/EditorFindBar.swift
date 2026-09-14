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
                TextField("Find in file", text: $find.query)
                    .textFieldStyle(.themed)
                    #if os(macOS)
                    .disableAutocorrection(true)
                    #else
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .focused($queryFocused)
                    .accessibilityLabel("Find in file")
                    .onSubmit { find.goNext() }
                if let count = find.countLabel {
                    Text(count)
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.controlGlyph)
                        .accessibilityLabel("\(count) matches")
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
                .accessibilityLabel("Previous match")
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
                .accessibilityLabel("Next match")
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!find.canNavigate)
                Button(find.replacing ? "Hide replace" : "Replace") { find.replacing.toggle() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .accessibilityLabel(find.replacing ? "Hide replace" : "Show replace")
                Spacer(minLength: 0)
                Button {
                    find.showing = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.controlGlyph)
                .accessibilityLabel("Close find")
            }
            if find.replacing {
                TextField("Replace with", text: $find.replaceText)
                    .textFieldStyle(.themed)
                    #if os(macOS)
                    .disableAutocorrection(true)
                    #else
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .accessibilityLabel("Replace with")
                HStack(spacing: Theme.Space.s) {
                    Button("Replace") { find.replaceCurrent() }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(!find.canReplace)
                    Button("Replace all") { find.replaceAll() }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(!find.canReplace)
                    if find.composing {
                        Text("Finish the current word first.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.controlGlyph)
                    } else {
                        Text("Replace all is one undo, in this file only.")
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
