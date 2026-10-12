// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import SwiftUI

struct WorkspaceDirectoryPlaceholder: View {
    var presentation: WorkspaceDirectoryPresentation
    var error: String?
    var compact = false
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if presentation == .failed {
                Text(FriendlyError.from(error ?? "").message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("common.retry"), .refresh, action: retry)
                    .buttonStyle(SecondaryButtonStyle(small: true))
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(0..<(compact ? 3 : 5), id: \.self) { row in
                        HStack(spacing: Theme.Space.s) {
                            Skeleton.Bar(width: compact ? 18 : 28, height: compact ? 18 : 28,
                                         phase: Double(row) * 0.08)
                            VStack(alignment: .leading, spacing: 6) {
                                Skeleton.Bar(width: row.isMultiple(of: 2) ? 128 : 96,
                                             phase: Double(row) * 0.08)
                                if !compact {
                                    Skeleton.Bar(width: 180, height: 9, phase: Double(row) * 0.08 + 0.04)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("apple.pullsview.loading.ba3bbbe1"))
                .accessibilityIdentifier("workspaces.loading")
                .allowsHitTesting(false)
            }
        }
        .padding(compact ? Theme.Space.m : Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
