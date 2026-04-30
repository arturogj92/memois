import SwiftUI

struct SubtitlesPanelView: View {
    @ObservedObject var service: LiveTranscriptionService
    @ObservedObject var settings: SettingsStore

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusDot
                Text(statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let lang = service.detectedLanguage {
                    Text(lang.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if service.status == .live || service.status == .connecting {
                    diagnosticsHUD
                }
            }

            if let fmt = service.audioFormatInfo {
                Text(fmt)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if service.committedTurns.isEmpty && service.partial.isEmpty {
                            Text(placeholderText)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .id("placeholder")
                        }

                        ForEach(service.committedTurns) { turn in
                            Text(turn.text)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(turn.id)
                        }

                        if !service.partial.isEmpty {
                            Text(service.partial)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("partial")
                        } else {
                            Color.clear.frame(height: 1).id("partial")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: service.committedTurns.count) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("partial", anchor: .bottom)
                    }
                }
                .onChange(of: service.partial) { _ in
                    proxy.scrollTo("partial", anchor: .bottom)
                }
            }
        }
        .padding(8)
        .padding(.bottom, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 0.5)
        )
    }

    private var diagnosticsHUD: some View {
        HStack(spacing: 6) {
            // Audio peak meter — fills with green proportional to peak level
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 36, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(peakColor)
                    .frame(width: 36 * CGFloat(min(1.0, max(0.0, service.peakLevel * 3.0))), height: 4)
                    .animation(.easeOut(duration: 0.08), value: service.peakLevel)
            }
            Text(formattedBytes(service.bytesSent))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            if let evt = service.lastEventType {
                Text(evt)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var peakColor: Color {
        let p = service.peakLevel
        if p < 0.01 { return .gray.opacity(0.6) }
        if p < 0.1 { return .yellow }
        return .green
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 6, height: 6)
    }

    private var statusColor: Color {
        switch service.status {
        case .live: return .green
        case .connecting: return .yellow
        case .error: return .red
        case .stopped, .idle: return .gray
        }
    }

    private var statusLabel: String {
        switch service.status {
        case .idle: return "Off"
        case .connecting: return "Connecting…"
        case .live: return "Live"
        case .stopped: return "Stopped"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var placeholderText: String {
        switch service.status {
        case .live: return "Listening…"
        case .connecting: return "Connecting to AssemblyAI…"
        default: return "Subtitles will appear here."
        }
    }

    private func formattedBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.0fK", kb) }
        let mb = kb / 1024.0
        return String(format: "%.1fM", mb)
    }
}
