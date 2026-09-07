import SwiftUI

/// A label/value line. Values are read straight off the coordinators, so what is
/// on screen is what SignalKit currently believes.
struct StateRow: View {
    let label: String
    let value: String
    var warn = false

    init(_ label: String, _ value: String, warn: Bool = false) {
        self.label = label; self.value = value; self.warn = warn
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(warn ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

/// A numeric knob with the package default called out, because the defaults are
/// the interesting part of the API.
struct StepperRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var suffix = ""
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Stepper(value: $value, in: range, step: step) {
                HStack {
                    Text(label)
                    Spacer()
                    Text("\(value)\(suffix)").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var format = "%.0f"
    var suffix = ""
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value) + suffix).foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: $value, in: range, step: step)
            if let note {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Shown whenever a construction-time setting no longer matches the live
/// services. Rebuilding preserves durable files, so nothing queued is lost.
struct RebuildBanner: View {
    @Environment(DemoServices.self) private var services

    var body: some View {
        if services.needsRebuild {
            Section {
                Button {
                    services.rebuild()
                } label: {
                    Label("Rebuild services to apply", systemImage: "arrow.clockwise")
                }
                Text("These settings are read once, when a coordinator is constructed. "
                     + "Rebuilding stops the current ones and makes new ones over the same "
                     + "directory — queued uploads survive it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
