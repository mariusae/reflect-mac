import SwiftUI
import ReflectCore
import UIKit

/// Settings: the style notes are set in — Ideal Sans, New York, the
/// system's — and how large, each shown as it reads, in a sample, before
/// it is chosen.
struct SettingsView: View {
    @State private var face = Typeface.current
    @State private var size = Double(PhoneState.size)
    /// Told when the style or size changed: the sheets set again.
    let onChange: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    sample
                        .listRowBackground(Color(Ink.card))
                }
                Section("Style") {
                    ForEach(Typeface.available) { option in
                        Button {
                            face = option
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .font(Font(option.body(17) as CTFont))
                                        .foregroundStyle(Color(Ink.text))
                                    Text(option.detail).font(.footnote).foregroundStyle(.secondary)
                                }
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
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
        .onChange(of: face) { _, face in
            Typeface.current = face
            onChange()
        }
        .onChange(of: size) { _, size in
            PhoneState.size = CGFloat(size)
            onChange()
        }
    }

    /// A few rows as a note sets them, in the style and size chosen.
    private var sample: some View {
        let metrics = PhoneMetrics(face: face, size: CGFloat(size), spacing: PhoneSpacing.of(face))
        let lineSpacing = max(0, (metrics.lineHeight - 1.2) * metrics.size)
        return VStack(alignment: .leading, spacing: metrics.rowGap) {
            Text("Sunday, October 4")
                .font(Font(metrics.heading(1) as CTFont))
                .padding(.bottom, 4)
            ForEach(Array(["Read the notes, then look over the calendar for the week",
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
