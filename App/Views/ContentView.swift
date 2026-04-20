import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    private let haBlue = Color(red: 3 / 255, green: 169 / 255, blue: 244 / 255)
    private let haBlueDeep = Color(red: 2 / 255, green: 119 / 255, blue: 189 / 255)
    private let haOrange = Color(red: 255 / 255, green: 152 / 255, blue: 0 / 255)
    private let haSurface = Color(red: 245 / 255, green: 247 / 255, blue: 250 / 255)
    private let haCard = Color.white.opacity(0.98)
    private let haBorder = Color(red: 225 / 255, green: 229 / 255, blue: 234 / 255)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                metrics
                HStack(alignment: .top, spacing: 20) {
                    settingsPanel
                    activityPanel
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(backgroundGradient)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 58, height: 58)

                    Image(systemName: "house.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Wyoming Apple Speech Server")
                        .font(.system(size: 31, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("A Home Assistant-style local voice endpoint for fast, on-device Apple speech recognition.")
                        .font(.headline)
                        .foregroundStyle(Color.white.opacity(0.88))
                }

                Spacer(minLength: 12)
            }

            HStack(alignment: .bottom, spacing: 16) {
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Button("Start") {
                        Task {
                            await model.startServer()
                        }
                    }
                    .buttonStyle(HAActionButtonStyle(fill: haOrange, text: .white))
                    .disabled(!model.canStart)

                    Button("Restart") {
                        Task {
                            await model.restartServer()
                        }
                    }
                    .buttonStyle(HAOutlineButtonStyle(accent: .white))
                    .disabled(!model.canStop)

                    Button("Stop") {
                        model.stopServer()
                    }
                    .buttonStyle(HAOutlineButtonStyle(accent: .white))
                    .disabled(!model.canStop)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [haBlue, haBlueDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .shadow(color: haBlue.opacity(0.22), radius: 18, y: 8)
    }

    private var metrics: some View {
        HStack(spacing: 16) {
            MetricTile(title: "Status", value: statusTitle, accent: statusTint, symbol: "dot.radiowaves.left.and.right")
            MetricTile(title: "Discovery", value: model.advertisedServiceType, accent: haBlue, symbol: "bonjour")
            MetricTile(title: "Clients", value: "\(model.activeClientCount)", accent: haOrange, symbol: "person.2.fill")
            MetricTile(title: "Locale", value: model.preferredLocaleIdentifier, accent: .green, symbol: "globe")
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Server Settings", icon: "slider.horizontal.3")

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Service Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Wyoming Apple Speech", text: $model.serviceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("TCP Port")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("10300", text: $model.portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferred Locale")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Preferred Locale", selection: $model.preferredLocaleIdentifier) {
                        ForEach(model.localeOptions) { option in
                            Text(model.localePickerLabel(for: option))
                                .tag(option.identifier)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.isInstallingLocale)
                }

                Toggle("Start the server automatically on launch", isOn: $model.autoStart)
            }
            .onChange(of: model.preferredLocaleIdentifier) { _, _ in
                Task {
                    await model.handlePreferredLocaleSelectionChange()
                }
            }

            statusCallout

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Home Assistant", icon: "house.and.flag")
                Text("The app advertises itself as `_wyoming._tcp.local.` and defaults to port `10300`, which matches typical Wyoming deployments.")
                    .foregroundStyle(.secondary)
                Text("All locales Apple supports are shown here. If you pick one that is not installed yet, the app downloads the speech assets and shows progress before using it.")
                    .foregroundStyle(.secondary)
                Text("If discovery does not appear immediately, add the Wyoming Protocol integration manually and point it at this Mac’s LAN IP plus the chosen port.")
                    .foregroundStyle(.secondary)
            }

            if !model.installedLocaleOptions.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Installed Speech Assets", icon: "square.stack.3d.down.right")

                    ForEach(model.installedLocaleOptions) { option in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.localeDisplayName(for: option.identifier))
                                Text("\(option.identifier) - \(model.localeAvailability(for: option).label)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if model.localeRemovalIdentifier == option.identifier {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button("Remove") {
                                    Task {
                                        await model.removeLocale(identifier: option.identifier)
                                    }
                                }
                                .buttonStyle(HAOutlineButtonStyle(accent: haOrange))
                                .disabled(!model.canRemoveLocale(option.identifier))
                            }
                        }
                        .padding(12)
                        .background(tileBackground(highlight: Color.black.opacity(0.025)))
                    }

                    Text("Removing a locale releases this app's reservation. macOS may delete the downloaded Apple speech assets later instead of immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 360, alignment: .leading)
        .background(panelBackground(accent: haBlue))
    }

    private var statusCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected locale: \(model.selectedLocaleAvailabilityLabel)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if let download = model.localeDownloadState {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Downloading \(download.displayName)")
                        Spacer()
                        Text("\(Int(download.progress * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: download.progress)
                        .progressViewStyle(.linear)

                    Button("Cancel Download") {
                        model.cancelLocaleInstallation()
                    }
                    .buttonStyle(HAOutlineButtonStyle(accent: haOrange))
                }
                .padding(14)
                .background(tileBackground(highlight: haOrange.opacity(0.16)))
            }

            if let error = model.localeInstallErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Recent Transcripts", icon: "waveform.badge.mic")

                if model.recentTranscripts.isEmpty {
                    PlaceholderPanel(message: "Transcripts will appear here after Wyoming clients send `audio-start` / `audio-chunk` / `audio-stop` events.")
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.recentTranscripts) { transcript in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(transcript.client)
                                        .font(.headline)
                                    Spacer()
                                    Text(Self.transcriptTimestampFormatter.string(from: transcript.timestamp))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text(transcript.text)
                                    .textSelection(.enabled)

                                if let language = transcript.language {
                                    Text(language)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(tileBackground(highlight: haBlue.opacity(0.10)))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Server Log", icon: "list.bullet.rectangle.portrait")

                HStack {
                    Text("\(model.logs.count) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Newest") {
                        model.showNewestLogs()
                    }
                    .buttonStyle(HAOutlineButtonStyle(accent: haBlue))
                    .disabled(model.logPage == 0)

                    Button("Previous") {
                        model.showPreviousLogPage()
                    }
                    .buttonStyle(HAOutlineButtonStyle(accent: haBlue))
                    .disabled(!model.canGoToPreviousLogPage)

                    Text(model.logPageLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 84)

                    Button("Next") {
                        model.showNextLogPage()
                    }
                    .buttonStyle(HAOutlineButtonStyle(accent: haBlue))
                    .disabled(!model.canGoToNextLogPage)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.paginatedLogs) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Text(Self.logTimestampFormatter.string(from: entry.timestamp))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 84, alignment: .leading)

                                HStack(alignment: .top, spacing: 8) {
                                    Text(entry.message)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    if entry.repetitionCount > 1 {
                                        Text("×\(entry.repetitionCount)")
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                            .foregroundStyle(haBlueDeep)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(haBlue.opacity(0.12))
                                            )
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 220)
                .padding(14)
                .background(tileBackground(highlight: Color.black.opacity(0.025)))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground(accent: haOrange))
    }

    private var backgroundGradient: some View {
        haSurface
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [haBlue.opacity(0.14), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 220)
                .ignoresSafeArea()
            }
    }

    private func panelBackground(accent: Color) -> some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(haCard)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(haBorder, lineWidth: 1)
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.16), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 82)
                    .mask(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .shadow(color: Color.black.opacity(0.05), radius: 10, y: 3)
    }

    private func tileBackground(highlight: Color) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(haBorder, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(highlight)
            )
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(haBlue)
            Text(title)
                .font(.title3.weight(.semibold))
        }
    }

    private var statusTitle: String {
        switch model.serverPhase {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case let .failed(message):
            return "Failed: \(message)"
        }
    }

    private var statusTint: Color {
        switch model.serverPhase {
        case .stopped:
            return .secondary
        case .starting:
            return haOrange
        case .running:
            return .green
        case .failed:
            return .red
        }
    }

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let transcriptTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct MetricTile: View {
    let title: String
    let value: String
    let accent: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(accent)
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(accent.opacity(0.28), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
        }
    }
}

private struct PlaceholderPanel: View {
    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    )
            )
    }
}

private struct HAActionButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(text)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.82 : 1))
            )
    }
}

private struct HAOutlineButtonStyle: ButtonStyle {
    let accent: Color

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let foregroundColor = isEnabled ? accent.opacity(configuration.isPressed ? 0.82 : 1) : .secondary.opacity(0.7)
        let backgroundColor = isEnabled ? Color.white.opacity(configuration.isPressed ? 0.12 : 0.08) : Color.black.opacity(0.035)
        let borderColor = isEnabled ? accent.opacity(0.4) : Color.black.opacity(0.08)

        configuration.label
            .font(.headline)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
    }
}
