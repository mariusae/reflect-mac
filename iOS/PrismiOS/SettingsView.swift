import SwiftUI
import ReflectCore
import UIKit

/// Settings: the face notes are set in, and how large — each shown as it
/// reads, in a sample, before it is chosen.
struct SettingsView: View {
    @State private var face = Typeface.current
    @State private var size = Double(PhoneState.size)
    @State private var spacing = PhoneSpacing.of(Typeface.current)
    /// Told when the face or size changed: the sheets set again.
    let onChange: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    sample
                        .listRowBackground(Color(Ink.card))
                }
                Section("Font") {
                    ForEach(Typeface.allCases) { option in
                        Button {
                            face = option
                        } label: {
                            HStack {
                                Text(option.title)
                                    .font(Font(option.body(17) as CTFont))
                                    .foregroundStyle(Color(Ink.text))
                                Spacer()
                                if option == face {
                                    Image(systemName: "checkmark").foregroundStyle(Color(Ink.accent)).fontWeight(.semibold)
                                }
                            }
                        }
                    }
                }
                Section("Text Size") {
                    HStack(spacing: 14) {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: $size, in: 13...22, step: 1)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    }
                    Text("\(Int(size)) pt").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    setting("Line height", $spacing.lineHeight, 1.1...1.8, step: 0.02, unit: "em")
                    setting("Space between rows", $spacing.rowSpacing, 0...0.8, step: 0.02, unit: "em")
                    setting("Outline indent", $spacing.indent, 0.9...2.2, step: 0.05, unit: "em")
                    setting("Heading size", $spacing.headingScale, 1.0...2.0, step: 0.01, unit: "×")
                    Picker("Heading style", selection: Binding(get: { spacing.headingCase ?? .family },
                                                               set: { spacing.headingCase = $0 == .family ? nil : $0 })) {
                        ForEach(HeadingCase.allCases, id: \.self) { option in Text(option.title).tag(option) }
                    }
                    Button("Reset \(face.title) to Defaults") { spacing = PhoneSpacing.defaults(face) }
                        .disabled(spacing == PhoneSpacing.defaults(face))
                } header: {
                    Text("Spacing")
                } footer: {
                    Text("Kept for each font: \(face.title)'s, as set here.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
        .onChange(of: face) { _, face in
            Typeface.current = face
            // Each face its own spacing: the one chosen's, as it was left.
            spacing = PhoneSpacing.of(face)
            onChange()
        }
        .onChange(of: spacing) { _, spacing in
            PhoneSpacing.set(spacing, for: face)
            changeSoon()
        }
        .onChange(of: size) { _, size in
            PhoneState.size = CGFloat(size)
            onChange()
        }
    }

    /// A slider, its name over it, its value beside the name.
    private func setting(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text(unit == "×" ? String(format: "%.2f×", value.wrappedValue) : String(format: "%.2f %@", value.wrappedValue, unit))
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    /// The sheets set again a moment after a slider stops: not for each step of it.
    @State private var pending: Task<Void, Never>?

    private func changeSoon() {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            onChange()
        }
    }

    /// A few rows as a note sets them, in the face and size chosen.
    private var sample: some View {
        let metrics = PhoneMetrics(face: face, size: CGFloat(size), spacing: spacing)
        let lineSpacing = max(0, (metrics.lineHeight - 1.2) * metrics.size)
        return VStack(alignment: .leading, spacing: metrics.rowGap) {
            Text("Sunday, October 4")
                .font(Font(metrics.heading(1) as CTFont))
                .textCase(metrics.headingsInCapitals ? .uppercase : nil)
                .tracking(metrics.headingsInCapitals ? metrics.size * CGFloat(HeadingCase.capitalsTracking) : 0)
                .padding(.bottom, 4)
            ForEach(Array(["Read the notes on cards, then look over the calendar for the week",
                           "Lunch with Ana", "Bring the book back"].enumerated()), id: \.offset) { i, row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(Color(Ink.secondary)).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    Text(row).font(Font(metrics.body as CTFont)).lineSpacing(lineSpacing)
                }
                .padding(.leading, i == 2 ? metrics.indent : 0)
            }
        }
        .foregroundStyle(Color(Ink.text))
        .padding(.vertical, 8)
    }
}
