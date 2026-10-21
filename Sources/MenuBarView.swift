import SwiftUI
import HiCrispSupport

struct MenuBarView: View {
    @ObservedObject var displayManager: DisplayManager
    @ObservedObject var virtualDisplayManager: VirtualDisplayManager
    @AppStorage("experimentalMatchPhysicalColorProfile") private var experimentalMatchPhysicalColorProfile = false
    @State private var status: Status?
    @State private var selectedHzByDisplay: [String: Double] = [:]

    private enum Status: Equatable {
        case working(String)
        case succeeded(String)
        case failed(String)

        var message: String {
            switch self {
            case .working(let message), .succeeded(let message), .failed(let message):
                return message
            }
        }
    }

    var body: some View {
        let externals = displayManager.displays.filter { !$0.isBuiltIn && $0.vendorID != VirtualDisplayManager.virtualVendorID }

        VStack(spacing: 0) {
            HStack {
                Text("HiCrisp")
                    .font(.headline)
                Spacer()
                Button(action: { displayManager.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r")
                .help("Rescan displays")
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
                VStack(spacing: 6) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No external displays found")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            } else {
                VStack(spacing: 12) {
                    ForEach(externals) { display in
                        monitorCard(display)
                    }
                }
                .padding(12)
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

            if let status {
                Divider()
                HStack(spacing: 6) {
                    switch status {
                    case .working:
                        ProgressView()
                            .controlSize(.small)
                    case .succeeded:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                    Text(status.message)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(action: { self.status = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .task(id: status) {
                    // Successes clear themselves; errors and in-progress messages stay until replaced or dismissed.
                    guard case .succeeded = status else { return }
                    try? await Task.sleep(for: .seconds(5))
                    if !Task.isCancelled {
                        self.status = nil
                    }
                }
            }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 300)
        .onChange(of: virtualDisplayManager.lastError) { error in
            // Also catches failures nobody triggered, like macOS terminating the virtual display.
            if let error {
                status = .failed(error)
            }
        }
    }

    // MARK: - Monitor Card

    @ViewBuilder
    private func monitorCard(_ display: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "display")
                    .foregroundColor(.accentColor)
                Text(display.name)
                    .font(.system(.body, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                statusBadge(display)
            }

            // Current mode info
            HStack(spacing: 4) {
                Text("\(display.nativeWidth)x\(display.nativeHeight)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
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
                    .controlSize(.regular)
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
                    .controlSize(.regular)
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

                    Button(action: { enableHiDPI(display) }) {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Enable HiDPI")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
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
        status = .working("Setting up HiDPI on \(display.name)...")

        virtualDisplayManager.enableHiDPI(
            physicalDisplay: display,
            targetWidth: display.nativeWidth,
            targetHeight: display.nativeHeight,
            refreshRate: selectedRefreshRate(for: display),
            preferPhysicalColorProfile: experimentalMatchPhysicalColorProfile
        ) { success, message in
            status = success ? .succeeded(message) : .failed(message)
            if success {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    displayManager.refresh()
                }
            }
        }
    }

    private func disableHiDPI(_ display: DisplayInfo) {
        virtualDisplayManager.disableHiDPI()
        status = .succeeded("HiDPI disabled on \(display.name)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            displayManager.refresh()
        }
    }

    // MARK: - Refresh Rate Selection

    /// The picked rate for this monitor model, else the current rate, snapped to what the display offers.
    private func selectedRefreshRate(for display: DisplayInfo) -> Double {
        RefreshRateSupport.preferredRate(
            stored: selectedHzByDisplay[display.storageKey]
                ?? UserDefaults.standard.double(forKey: refreshRateDefaultsKey(for: display)),
            current: display.currentMode?.refreshRate,
            available: display.availableRefreshRates
        )
    }

    private func refreshRateBinding(for display: DisplayInfo) -> Binding<Double> {
        Binding(
            get: { selectedRefreshRate(for: display) },
            set: { hz in
                selectedHzByDisplay[display.storageKey] = hz
                UserDefaults.standard.set(hz, forKey: refreshRateDefaultsKey(for: display))
            }
        )
    }

    private func refreshRateDefaultsKey(for display: DisplayInfo) -> String {
        "refreshRate.\(display.storageKey)"
    }
}
