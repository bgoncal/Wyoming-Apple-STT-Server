import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                metrics
                HStack(alignment: .top, spacing: 20) {
                    settingsPanel
                    activityPanel
                }
            }
            .padding(28)
        }
        .background(backgroundGradient)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Wyoming Apple Speech Server")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))

                Text("A local macOS bridge that exposes Apple’s on-device speech-to-text through the Wyoming protocol for Home Assistant and other voice clients.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                Button("Start") {
                    Task {
                        await model.startServer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)

                Button("Restart") {
                    Task {
                        await model.restartServer()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!model.canStop)

                Button("Stop") {
                    model.stopServer()
                }
                .buttonStyle(.bordered)
                .disabled(!model.canStop)
            }
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private var metrics: some View {
        HStack(spacing: 16) {
            MetricTile(title: "Status", value: statusTitle, accent: statusTint)
            MetricTile(title: "Bonjour", value: model.advertisedServiceType, accent: .mint)
            MetricTile(title: "Clients", value: "\(model.activeClientCount)", accent: .blue)
            MetricTile(title: "Locale", value: model.preferredLocaleIdentifier, accent: .orange)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Settings")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Service Name") {
                    TextField("Wyoming Apple Speech", text: $model.serviceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }

                LabeledContent("TCP Port") {
                    TextField("10300", text: $model.portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                LabeledContent("Preferred Locale") {
                    Picker("Preferred Locale", selection: $model.preferredLocaleIdentifier) {
                        ForEach(model.availableLocaleIdentifiers, id: \.self) { identifier in
                            Text(model.localeDisplayName(for: identifier))
                                .tag(identifier)
                        }
                    }
                    .frame(width: 320)
                }

                Toggle("Start the server automatically on launch", isOn: $model.autoStart)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Home Assistant")
                    .font(.headline)
                Text("The app advertises itself as `_wyoming._tcp.local.` and defaults to port `10300`, which matches typical Wyoming deployments.")
                    .foregroundStyle(.secondary)
                Text("If discovery does not appear immediately, add the Wyoming Protocol integration manually and point it at this Mac’s LAN IP plus the chosen port.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(maxWidth: 360, alignment: .leading)
        .background(panelBackground(accent: .teal))
    }

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Transcripts")
                    .font(.title3.weight(.semibold))

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
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.5))
                            )
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Server Log")
                    .font(.title3.weight(.semibold))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.logs) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Text(Self.logTimestampFormatter.string(from: entry.timestamp))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 84, alignment: .leading)
                                Text(entry.message)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(minHeight: 220)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground(accent: .indigo))
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color.accentColor.opacity(0.08),
                Color.mint.opacity(0.06),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private func panelBackground(accent: Color) -> some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(accent.opacity(0.18), lineWidth: 1)
            )
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
            return .orange
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(accent.opacity(0.25), lineWidth: 1)
                )
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
                    .fill(Color.white.opacity(0.45))
            )
    }
}
