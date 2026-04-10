import SwiftUI

struct MenuBarView: View {
    @ObservedObject var displayManager: DisplayManager
    @ObservedObject var virtualDisplayManager: VirtualDisplayManager
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var selectedHz: Double = 0  // 0 = auto-detect from current mode

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("HiCrisp")
                    .font(.headline)
                Spacer()
                Button(action: { displayManager.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            let externals = displayManager.displays.filter { !$0.isBuiltIn }

            if externals.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No external displays found")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                VStack(spacing: 12) {
                    ForEach(externals) { display in
                        monitorCard(display)
                    }
                }
                .padding(12)
            }

            // Built-in display (compact)
            if let builtIn = displayManager.displays.first(where: { $0.isBuiltIn }) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "laptopcomputer")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(builtIn.name) - \(builtIn.currentMode?.label ?? "Unknown")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            // Status
            if let msg = statusMessage {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(statusIsError ? .orange : .green)
                    Text(msg)
                        .font(.caption)
                        .lineLimit(3)
                    Spacer()
                    Button(action: { statusMessage = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
    }

    // MARK: - Monitor Card

    @ViewBuilder
    private func monitorCard(_ display: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "display")
                    .foregroundColor(.accentColor)
                Text(display.name)
                    .font(.system(.body, weight: .semibold))
                Spacer()
                statusBadge(display)
            }

            // Current mode info
            HStack(spacing: 4) {
                Text("\(display.nativeWidth)x\(display.nativeHeight)")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                if let cur = display.currentMode {
                    Text("@ \(Int(cur.refreshRate))Hz")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if virtualDisplayManager.isActive {
                    Text("HiDPI")
                        .font(.caption2).bold()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                }
            }

            Divider()

            // Action area
            if virtualDisplayManager.isActive {
                // HiDPI is active
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("HiDPI active via virtual display")
                            .font(.callout)
                    }

                    Text("Text and UI are rendered at 2x resolution. Disabling will revert to standard rendering.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: { disableHiDPI(display) }) {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("Disable HiDPI")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                }
            } else {
                // HiDPI not active - offer to enable
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enable HiDPI rendering for sharp text and UI at your native resolution.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Refresh rate picker
                    let rates = display.availableRefreshRates
                    if rates.count > 1 {
                        HStack {
                            Text("Refresh rate:")
                                .font(.caption)
                            Picker("", selection: $selectedHz) {
                                ForEach(rates, id: \.self) { hz in
                                    Text("\(Int(hz))Hz").tag(hz)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 80)
                        }
                    }

                    // Auto-select current refresh rate on appear
                    Color.clear.frame(height: 0).onAppear {
                        if selectedHz == 0, let cur = display.currentMode {
                            selectedHz = cur.refreshRate
                        } else if selectedHz == 0, let first = rates.first {
                            selectedHz = first
                        }
                    }

                    Button(action: { enableHiDPI(display) }) {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Enable HiDPI")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)

                    Text("No system files are modified. Reverts when the app quits.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func statusBadge(_ display: DisplayInfo) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(virtualDisplayManager.isActive ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(virtualDisplayManager.isActive ? "HiDPI Active" : "Standard")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Actions

    private func enableHiDPI(_ display: DisplayInfo) {
        statusMessage = "Setting up HiDPI..."
        statusIsError = false

        virtualDisplayManager.enableHiDPI(
            physicalDisplay: display,
            targetWidth: display.nativeWidth,
            targetHeight: display.nativeHeight,
            refreshRate: selectedHz
        ) { success, message in
            statusMessage = message
            statusIsError = !success
            if success {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    displayManager.refresh()
                }
            }
        }
    }

    private func disableHiDPI(_ display: DisplayInfo) {
        virtualDisplayManager.disableHiDPI()
        statusMessage = "HiDPI disabled"
        statusIsError = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            displayManager.refresh()
        }
    }
}
