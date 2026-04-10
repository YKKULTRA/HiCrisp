import SwiftUI
import HiCrispSupport

struct MenuBarView: View {
    @ObservedObject var displayManager: DisplayManager
    @ObservedObject var virtualDisplayManager: VirtualDisplayManager
    @AppStorage("experimentalMatchPhysicalColorProfile") private var experimentalMatchPhysicalColorProfile = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var selectedHzByDisplay: [CGDirectDisplayID: Double] = [:]

    var body: some View {
        let externals = displayManager.displays.filter { !$0.isBuiltIn }

        VStack(spacing: 0) {
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

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Match monitor color profile", isOn: $experimentalMatchPhysicalColorProfile)
                    .toggleStyle(.switch)

                Text("Experimental. Off uses stable sRGB for the virtual display.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

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
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(externals) { display in
                            monitorCard(display)
                        }
                    }
                    .padding(12)
                }
                .frame(minHeight: 120, maxHeight: 320)
            }

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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            if let msg = statusMessage {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(statusIsError ? .orange : .green)
                    Text(msg)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(action: { statusMessage = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text("@ \(RefreshRateSupport.label(for: cur.refreshRate))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if virtualDisplayManager.isActive(for: display.id) {
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
            if virtualDisplayManager.isActive(for: display.id) {
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

                    if let activeSession = virtualDisplayManager.activeSession {
                        Text("Color profile: \(activeSession.profileDescription)")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        if activeSession.usedFallbackProfile {
                            Text("Requested physical profile matching was not available, so the session fell back to sRGB.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if activeSession.usesEstimatedPhysicalSize {
                            Text("Physical size was estimated because the display did not report EDID dimensions.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

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
            } else if virtualDisplayManager.isActive {
                VStack(alignment: .leading, spacing: 8) {
                    Text("HiDPI is already active on \(virtualDisplayManager.activeSession?.physicalDisplayName ?? "another display"). Disable that session before switching monitors.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: { virtualDisplayManager.disableHiDPI() }) {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("Disable Current Session")
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
                            Picker("", selection: refreshRateBinding(for: display)) {
                                ForEach(rates, id: \.self) { hz in
                                    Text(RefreshRateSupport.label(for: hz)).tag(hz)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 94)
                        }
                    }

                    // Auto-select current refresh rate on appear
                    Color.clear.frame(height: 0).onAppear {
                        syncSelectedRefreshRate(for: display)
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
        let isActiveForDisplay = virtualDisplayManager.isActive(for: display.id)
        let isBlockedByAnotherDisplay = virtualDisplayManager.isActive && !isActiveForDisplay
        let badgeColor = isActiveForDisplay ? Color.green : (isBlockedByAnotherDisplay ? Color.orange : Color.secondary)
        let label = isActiveForDisplay ? "HiDPI Active" : (isBlockedByAnotherDisplay ? "Session Elsewhere" : "Ready")

        HStack(spacing: 4) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Actions

    private func enableHiDPI(_ display: DisplayInfo) {
        syncSelectedRefreshRate(for: display)
        let refreshRate = selectedHzByDisplay[display.id]
            ?? RefreshRateSupport.preferredRate(
                stored: nil,
                current: display.currentMode?.refreshRate,
                available: display.availableRefreshRates
            )

        statusMessage = "Setting up HiDPI on \(display.name)..."
        statusIsError = false

        virtualDisplayManager.enableHiDPI(
            physicalDisplay: display,
            targetWidth: display.nativeWidth,
            targetHeight: display.nativeHeight,
            refreshRate: refreshRate,
            preferPhysicalColorProfile: experimentalMatchPhysicalColorProfile
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
        statusMessage = "HiDPI disabled on \(display.name)"
        statusIsError = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            displayManager.refresh()
        }
    }

    private func refreshRateBinding(for display: DisplayInfo) -> Binding<Double> {
        Binding(
            get: {
                selectedHzByDisplay[display.id]
                    ?? RefreshRateSupport.preferredRate(
                        stored: nil,
                        current: display.currentMode?.refreshRate,
                        available: display.availableRefreshRates
                    )
            },
            set: { selectedHzByDisplay[display.id] = $0 }
        )
    }

    private func syncSelectedRefreshRate(for display: DisplayInfo) {
        let preferred = RefreshRateSupport.preferredRate(
            stored: selectedHzByDisplay[display.id],
            current: display.currentMode?.refreshRate,
            available: display.availableRefreshRates
        )

        if preferred > 0 {
            selectedHzByDisplay[display.id] = preferred
        } else {
            selectedHzByDisplay.removeValue(forKey: display.id)
        }
    }
}
