import SwiftUI

/// The injected `DiagnosticLog` in one place. SignalKit never transmits these —
/// the sink is the host's, and the default discards everything.
struct LogTab: View {
    @Environment(DemoServices.self) private var services

    var body: some View {
        NavigationStack {
            List {
                if services.diagnostics.isEmpty {
                    Text("Nothing logged yet. Diagnostics are opt-in: this app passes a "
                         + "DiagnosticSink into both coordinators, and the package default "
                         + "discards every event.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(services.diagnostics.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                Button("Clear") { services.clearLog() }
                    .disabled(services.diagnostics.isEmpty)
            }
        }
    }
}
