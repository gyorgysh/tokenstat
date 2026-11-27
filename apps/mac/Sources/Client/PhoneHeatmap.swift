// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
#if !os(macOS)
import UIKit
#endif

#if !os(macOS)

struct PhoneHeatmap: View {
    let calendar: ActivityCalendar
    var onSelect: ((HeatCell) -> Void)?
    var onScrub: ((Bool) -> Void)?

    @State private var focus: Focus?
    @State private var scrubbing = false
    @State private var suppressTap = false

    private let cell: CGFloat = 15
    private let gap: CGFloat = 3.5
    private let corner: CGFloat = 3
    private let gutter: CGFloat = 16
    private let monthRow: CGFloat = 13

    private var step: CGFloat { cell + gap }
    private var gridHeight: CGFloat { step * 7 - gap }
    private var gridWidth: CGFloat { step * CGFloat(calendar.weeks) - gap }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            caption
            gridRow
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("apple.phoneheatmap.activity_calendar.60b300fd"))
        // The grid's own summary, so VoiceOver does not have to walk a year of
        // cells to learn what it is looking at.
        .accessibilityValue(summary)
        .accessibilityHint(L10n.text("apple.phoneheatmap.hold_a_day_to_read_its_date_and_amount_lif.d2f63c75"))
    }

    private var caption: some View {
        HStack(spacing: 6) {
            if let focus {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
                Text(shortDate(focus.day.date))
                    .font(Theme.font(13, weight: .semibold))
                Text(focus.day.value == 0
                    ? L10n.text("apple.phoneheatmap.nothing_recorded.ef5e03f6")
                    : L10n.text("apple.phoneheatmap.0_at_api_list_price.1faebace", "\(formatSpend(focus.day.value))"))
                    .font(Theme.font(12))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "hand.draw")
                    .font(Theme.font(11))
                    .foregroundStyle(.tertiary)
                Text(L10n.text("apple.phoneheatmap.swipe_for_the_whole_year_hold_a_day_to_rea.90159e22"))
                    .font(Theme.font(11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .frame(height: 18)
        .animation(.easeOut(duration: 0.12), value: focus?.day.id)
        .accessibilityHidden(true)
    }

    private var gridRow: some View {
        GeometryReader { proxy in
            let intrinsicWidth = gutter + 6 + gridWidth
            let fits = intrinsicWidth <= proxy.size.width

            Group {
                if fits {
                    HStack(alignment: .top, spacing: 6) {
                        weekdayLabels
                        calendarGrid
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        weekdayLabels
                        ScrollView(.horizontal, showsIndicators: true) {
                            calendarGrid
                        }
                        .defaultScrollAnchor(.trailing)
                        .scrollDisabled(scrubbing)
                        .clientHideScrollEdgeEffect()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: monthRow + 6 + gridHeight + 6)
    }

    private var calendarGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            monthLabels
            grid
        }
        .padding(.bottom, 6)
    }

    private var summary: String {
        var text = L10n.text("apple.phoneheatmap.0_active_days_1_at_api_list_price_2_to_3.99c7149b", "\(calendar.activeDays)", "\(formatSpend(calendar.total))", "\(spokenDate(calendar.first))", "\(spokenDate(calendar.last))")
        if calendar.isHistoryLocked {
            let days = calendar.historyDays ?? 30
            text += L10n.text("apple.phoneheatmap.last_0_days_are_clear_older_days_keep_the.5d9eddd2", "\(days)")
        }
        text += L10n.text("apple.phoneheatmap.days_with_activity_are_listed.6dc67e87")
        return text
    }

    private static var heatPalette: [Color] {
        let appearance = AppAppearance.shared
        guard appearance.paletteID == "default", appearance.mode != .oled else { return Theme.heat }
        return defaultHeatPalette
    }

    private static let defaultHeatPalette: [Color] = {
        var ramp = Theme.heat
        ramp[0] = Color.adaptive(
            light: Color(red: 0xDE / 255, green: 0xDA / 255, blue: 0xEA / 255),
            dark: Color(red: 0x22 / 255, green: 0x1E / 255, blue: 0x36 / 255)
        )
        return ramp
    }()

    private var weekdayLabels: some View {
        VStack(spacing: gap) {
            Color.clear.frame(width: gutter, height: monthRow)
            ForEach(0..<7, id: \.self) { row in
                Text(Self.rowLabel(row))
                    .font(Theme.fixed(9))
                    .foregroundStyle(.tertiary)
                    .frame(width: gutter, height: cell, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    private var monthLabels: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: monthRow)
            ForEach(calendar.months) { month in
                Text(month.name)
                    .font(Theme.fixed(10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .offset(x: CGFloat(month.column) * step)
            }
        }
        .frame(width: gridWidth, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var grid: some View {
        let ramp = Self.heatPalette
        let marked = focus
        return ZStack(alignment: .topLeading) {
            HeatmapCellsCanvas(rows: calendar.rows, cell: cell, gap: gap,
                               corner: corner, palette: ramp)
                .equatable()
            if let marked {
                let ring = marked.rect.insetBy(dx: -2, dy: -2)
                RoundedRectangle(cornerRadius: corner + 2)
                    .stroke(Theme.accent, lineWidth: 2)
                    .frame(width: ring.width, height: ring.height)
                    .offset(x: ring.minX, y: ring.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
        .contentShape(.rect)
        // A real long-press recognizer, not a SwiftUI gesture.
        //
        // The SwiftUI attempts both failed, in opposite ways. A composed
        // `LongPressGesture.sequenced(before:)` never resolved inside the
        // scroll view, so nothing fired at all. A `DragGesture` with zero
        // minimum distance did fire, and took one-finger scrolling with it:
        // the year could only be moved with two fingers, which nobody would
        // discover. `UILongPressGestureRecognizer` yields to the scroll view's
        // pan until the press is actually held, reports its location the whole
        // time it is held, and, unlike a `DragGesture`, tells us when the
        // system takes the touch away. See `PressTracker`.
        .overlay {
            PressTracker(
                onBegan: { point in
                    scrubbing = true
                    onScrub?(true)
                    focus = hit(at: point)
                    Self.tick()
                },
                onMoved: { point in
                    guard let hit = hit(at: point), hit.day.id != focus?.day.id else { return }
                    focus = hit
                    Self.tick()
                },
                onEnded: { point in
                    let landed = hit(at: point) ?? focus
                    endScrub()
                    guard let landed else { return }
                    onSelect?(landed.day)
                },
                onCancelled: { endScrub() }
            )
        }
        .simultaneousGesture(
            SpatialTapGesture().onEnded { event in
                guard !suppressTap, !scrubbing else { return }
                guard let landed = hit(at: event.location) else { return }
                onSelect?(landed.day)
            }
        )
        .accessibilityChildren {
            ForEach(accessibleDays) { day in
                Button {
                    onSelect?(day)
                } label: {
                    Text(L10n.text("apple.phoneheatmap.0_1_at_api_list_price.c7adc814", "\(spokenDate(day.date))", "\(formatSpend(day.value))"))
                }
            }
        }
    }

    /// A transparent view whose only job is to report a press and where it is.
    ///
    /// `UILongPressGestureRecognizer` is used rather than a SwiftUI gesture
    /// because it has the two properties this needs and SwiftUI's does not
    /// expose: it coexists with a scroll view's pan without claiming ordinary
    /// drags, and it reports `.cancelled`. Without that last one a hold
    /// interrupted by a call banner or Control Center left the grid stuck in
    /// scrub mode, unscrollable, with a label pinned to it.
    private struct PressTracker: UIViewRepresentable {
        var onBegan: (CGPoint) -> Void
        var onMoved: (CGPoint) -> Void
        var onEnded: (CGPoint) -> Void
        var onCancelled: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .clear
            // Transparent and not interactive on its own: taps and scrolls
            // pass through to the SwiftUI content underneath, and only the
            // recognizer below sees anything.
            view.isUserInteractionEnabled = true
            let press = UILongPressGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handle(_:))
            )
            press.minimumPressDuration = 0.2
            press.allowableMovement = 24
            press.cancelsTouchesInView = false
            press.delaysTouchesEnded = false
            press.delegate = context.coordinator
            view.addGestureRecognizer(press)
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            context.coordinator.parent = self
        }

        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var parent: PressTracker

            init(_ parent: PressTracker) {
                self.parent = parent
            }

            @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
                let point = recognizer.location(in: recognizer.view)
                switch recognizer.state {
                case .began: parent.onBegan(point)
                case .changed: parent.onMoved(point)
                case .ended: parent.onEnded(point)
                case .cancelled, .failed: parent.onCancelled()
                default: break
                }
            }

            // The tap that opens a day lives in SwiftUI, on the same view.
            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool {
                true
            }
        }
    }

    private func endScrub() {
        scrubbing = false
        onScrub?(false)
        focus = nil
        suppressTap = true
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            suppressTap = false
        }
    }

    private struct Focus: Equatable {
        var day: HeatCell
        var rect: CGRect
    }

    private func hit(at point: CGPoint) -> Focus? {
        let column = Int(point.x / step)
        let row = Int(point.y / step)
        guard row >= 0, row < calendar.rows.count else { return nil }
        let cells = calendar.rows[row]
        guard column >= 0, column < cells.count else { return nil }
        guard let day = cells[column] ?? nil, !day.isLocked else { return nil }
        let rect = CGRect(
            x: CGFloat(column) * step,
            y: CGFloat(row) * step,
            width: cell,
            height: cell
        )
        return Focus(day: day, rect: rect)
    }

    private static func tick() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// The days a screen reader can reach: the ones something happened on.
    ///
    /// A year is 365 focusable squares, and three hundred of them would say
    /// "nothing". Walking that to find last Tuesday is a maze, which is the
    /// thing the accessibility notes in `docs/ios-client-ui.md` name outright.
    /// The quiet days are not hidden information: the summary above carries the
    /// span and the active-day count, and the day sheet gives exact figures for
    /// any day at all.
    private var accessibleDays: [HeatCell] {
        calendar.rows.flatMap { $0.compactMap { $0 } }
            .filter { $0.value > 0 && !$0.isLocked }
            .sorted { $0.date > $1.date }
    }

    private static func rowLabel(_ row: Int) -> String {
        switch row {
        case 0: return L10n.text("apple.phoneheatmap.m.08f27188")
        case 2: return L10n.text("apple.phoneheatmap.w.fcb5f40d")
        case 4: return L10n.text("apple.phoneheatmap.f.f67ab10a")
        default: return ""
        }
    }
}

#endif
