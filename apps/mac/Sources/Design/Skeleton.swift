// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Skeleton {
    struct Bar: View {
        var width: CGFloat?
        var height: CGFloat = 12
        var phase: Double = 0

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            SkeletonPulse(phase: phase, animates: !reduceMotion)
                .frame(width: width, height: height)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        }
    }

    struct Rows: View {
        var count: Int = 5
        var showsValue = true

        var body: some View {
            VStack(spacing: Theme.Space.s) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(spacing: Theme.Space.s) {
                        Bar(
                            width: Self.labelWidths[index % Self.labelWidths.count],
                            height: 9,
                            phase: Double(index) * 0.08
                        )
                        Spacer(minLength: Theme.Space.s)
                        if showsValue {
                            Bar(width: 44, height: 9, phase: Double(index) * 0.08 + 0.04)
                        }
                    }
                }
            }
        }

        private static let labelWidths: [CGFloat] = [128, 96, 152, 84, 116, 104]
    }

    struct CardPlaceholder: View {
        var rows: Int = 3

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 6) {
                    Bar(width: 116, height: 10, phase: 0)
                    Bar(width: 168, height: 8, phase: 0.06)
                }
                Rows(count: rows)
            }
            .opacity(0.75)
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
    }

    struct CardStack: View {
        var count: Int = 4
        var rows: Int = 2

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(0..<count, id: \.self) { _ in CardPlaceholder(rows: rows) }
            }
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0.4), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)
        }
    }
}

struct Warming: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.allowsHitTesting(!active)
    }
}

extension View {
    func warming(_ active: Bool) -> some View {
        modifier(Warming(active: active))
    }
}

extension AnyTransition {
    static func smoothIn(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4))
    }
}

struct DiffSkeleton: View {
    var lines = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(0..<lines, id: \.self) { index in
                HStack(spacing: Theme.Space.s) {
                    Skeleton.Bar(width: 22, height: 7, phase: Double(index) * 0.05)
                    Skeleton.Bar(width: 22, height: 7, phase: Double(index) * 0.05)
                    Skeleton.Bar(width: Self.widths[index % Self.widths.count], height: 8, phase: Double(index) * 0.05)
                        .padding(.leading, Theme.Space.s + CGFloat(Self.indents[index % Self.indents.count]) * 14)
                    Spacer(minLength: 0)
                }
            }
        }
        .opacity(0.75)
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private static let widths: [CGFloat] = [220, 310, 180, 260, 140, 340, 200]
    private static let indents = [0, 1, 1, 2, 2, 1, 0]
}

struct PanelListSkeleton: View {
    var rows = 12
    var twoLine = false

    var body: some View {
        VStack(alignment: .leading, spacing: twoLine ? 14 : 12) {
            ForEach(0..<rows, id: \.self) { index in
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Skeleton.Bar(width: twoLine ? 20 : 13, height: twoLine ? 20 : 11, phase: Double(index) * 0.05)
                    VStack(alignment: .leading, spacing: 6) {
                        Skeleton.Bar(width: Self.widths[index % Self.widths.count], height: 9, phase: Double(index) * 0.05)
                        if twoLine {
                            Skeleton.Bar(width: 110, height: 7, phase: Double(index) * 0.05 + 0.04)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .opacity(0.75)
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .accessibilityHidden(true)
    }

    private static let widths: [CGFloat] = [150, 96, 178, 120, 164, 88]
}

struct ReviewSkeleton: View {
    var body: some View {
        HStack(spacing: 0) {
            PanelListSkeleton(rows: 8).frame(width: 220)
            Rectangle().fill(Theme.border).frame(width: 1)
            DiffSkeleton(lines: 18).frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The grey bar and its pulse, drawn by Core Animation.
///
/// Not a SwiftUI animation. A view being removed stays alive until its
/// animations have finished, and one that repeats for ever never finishes: a
/// placeholder replaced inside an animated change went on being drawn, out of
/// sight, for the rest of the session, at a third of the main thread. Here the
/// pulse runs in the render server and ends with the layer.
#if os(macOS)
struct SkeletonPulse: NSViewRepresentable {
    let phase: Double
    let animates: Bool

    func makeNSView(context: Context) -> SkeletonPulseView { SkeletonPulseView() }
    func updateNSView(_ view: SkeletonPulseView, context: Context) { view.set(phase: phase, animates: animates) }
}

final class SkeletonPulseView: NSView {
    private var phase = 0.0
    private var animates = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = NSColor(Theme.border).cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restart()
    }

    func set(phase: Double, animates: Bool) {
        guard self.phase != phase || self.animates != animates || layer?.backgroundColor == nil else { return }
        self.phase = phase
        self.animates = animates
        needsDisplay = true
        restart()
    }

    private func restart() {
        guard let layer else { return }
        SkeletonPulseMotion.apply(to: layer, phase: phase, animates: animates && window != nil)
    }
}
#else
struct SkeletonPulse: UIViewRepresentable {
    let phase: Double
    let animates: Bool

    func makeUIView(context: Context) -> SkeletonPulseView { SkeletonPulseView() }
    func updateUIView(_ view: SkeletonPulseView, context: Context) { view.set(phase: phase, animates: animates) }
}

final class SkeletonPulseView: UIView {
    private var phase = 0.0
    private var animates = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(Theme.border)
        layer.cornerRadius = 4
        layer.cornerCurve = .continuous
        NotificationCenter.default.addObserver(self, selector: #selector(restart),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restart()
    }

    func set(phase: Double, animates: Bool) {
        guard self.phase != phase || self.animates != animates else { return }
        self.phase = phase
        self.animates = animates
        restart()
    }

    @objc private func restart() {
        SkeletonPulseMotion.apply(to: layer, phase: phase, animates: animates && window != nil)
    }
}
#endif

private enum SkeletonPulseMotion {
    static func apply(to layer: CALayer, phase: Double, animates: Bool) {
        layer.removeAnimation(forKey: "pulse")
        guard animates else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.52
        pulse.toValue = 1
        pulse.duration = 0.95
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.timeOffset = phase
        layer.add(pulse, forKey: "pulse")
    }
}
