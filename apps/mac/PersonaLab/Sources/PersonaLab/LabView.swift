// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The tuning bench for persona motion.
///
/// Three questions, one window. Does a mood read at a glance? Does it still
/// read at 18pt, which is the size most of them are actually seen at? And what
/// does a screen full of them cost?
struct LabView: View {
    @State private var mood: PersonaMood = .idle
    @State private var seed: UInt64 = 0x51ED_2764_A11C_0001
    @State private var heroSize: CGFloat = 190
    @State private var cycling = false
    @State private var stillness = false
    @State private var stressCount: Double = 0
    @State private var bench: LabBench.Result?
    @State private var dark = true

    private static let sizes: [CGFloat] = [18, 26, 64]

    var body: some View {
        HStack(spacing: 0) {
            stage
                .frame(width: 400)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    moodGallery
                    cast
                    stress
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .preferredColorScheme(dark ? .dark : .light)
        .task(id: cycling) {
            guard cycling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1900))
                guard !Task.isCancelled else { return }
                let all = PersonaMood.allCases
                let next = (all.firstIndex(of: mood).map { $0 + 1 } ?? 0) % all.count
                mood = all[next]
            }
        }
    }

    // MARK: - Stage

    private var stage: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.accent.opacity(0.07))
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.16), lineWidth: 1)
                if stillness {
                    LabStillMark(seed: seed, size: heroSize, state: mood)
                } else {
                    PersonaMark(seed: seed, size: heroSize, state: mood, pokeable: true)
                }
            }
            .frame(height: 300)

            Text(String(describing: mood))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("click the character to shove it")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            moodPicker

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("size").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: $heroSize, in: 24...260)
                    Text("\(Int(heroSize))")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 30, alignment: .trailing)
                }
                HStack(spacing: 10) {
                    Button("reroll seed") { seed = UInt64.random(in: 1...UInt64.max) }
                    Toggle("cycle", isOn: $cycling)
                    Toggle("still", isOn: $stillness)
                    Toggle("dark", isOn: $dark)
                }
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .padding(.horizontal, 4)

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var moodPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(PersonaMood.allCases, id: \.self) { option in
                Button {
                    mood = option
                } label: {
                    Text(String(describing: option))
                        .font(.system(size: 11, weight: option == mood ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(option == mood ? Theme.accent.opacity(0.24) : Theme.accent.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Gallery

    private var moodGallery: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("every mood, at the sizes it is really seen")
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 4),
                spacing: 18
            ) {
                ForEach(PersonaMood.allCases, id: \.self) { option in
                    VStack(spacing: 8) {
                        HStack(alignment: .bottom, spacing: 12) {
                            ForEach(Self.sizes, id: \.self) { size in
                                PersonaMark(seed: seed, size: size, state: option)
                            }
                        }
                        .frame(height: 72)
                        Text(String(describing: option))
                            .font(.system(size: 10))
                            .foregroundStyle(option == mood ? Theme.accent : .secondary)
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.accent.opacity(option == mood ? 0.10 : 0.04))
                    )
                    .onTapGesture { mood = option }
                }
            }
        }
    }

    private var cast: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("twelve seeds, one mood: firmness, lumps and features")
            HStack(spacing: 14) {
                ForEach(0..<12, id: \.self) { index in
                    PersonaMark(
                        seed: UInt64(index &* 0x9E37_79B9 &+ 17) | 1,
                        size: 58,
                        state: mood
                    )
                }
            }
        }
    }

    // MARK: - Cost

    private var stress: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("cost")
            HStack(spacing: 16) {
                Slider(value: $stressCount, in: 0...240)
                    .frame(width: 240)
                Text("\(Int(stressCount)) live marks")
                    .font(.system(size: 11, design: .monospaced))
                LabFrameMeter()
            }
            if stressCount > 0 {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 24),
                    spacing: 4
                ) {
                    ForEach(0..<Int(stressCount), id: \.self) { index in
                        PersonaMark(
                            seed: UInt64(index &* 2_654_435_761 &+ 7) | 1,
                            size: 26,
                            state: mood
                        )
                    }
                }
            }
            HStack(spacing: 12) {
                Button("benchmark the simulation alone") {
                    bench = LabBench.run(bodies: 120, seconds: 10, mood: mood)
                }
                if let bench {
                    Text(bench.summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
