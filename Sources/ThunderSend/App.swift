import AppKit
import SwiftUI

@main
struct ThunderSendApp: App {
    @State private var link = Link()

    var body: some Scene {
        Window("ThunderSend", id: "main") {
            ContentView(link: link)
                .frame(width: 360, height: 400)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

struct ContentView: View {
    let link: Link
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: link.peerName == nil ? "bolt.horizontal.circle" : "bolt.horizontal.circle.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(link.peerName == nil ? Color.secondary : Color.accentColor)
                .symbolEffect(.pulse, isActive: link.connected && link.peerName == nil)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(.horizontal, 24)

            Spacer()

            if let progress {
                ProgressView(value: progress)
                    .padding(.horizontal, 40)
                    .frame(height: 32)
            } else {
                Button("Choose Folder…", action: choose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(link.peerName == nil)
                    .frame(height: 32)
            }
        }
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(targeted ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, link.peerName != nil else { return false }
            Task { await link.send(url) }
            return true
        } isTargeted: { targeted = $0 }
    }

    private var title: String {
        if let peer = link.peerName { return peer }
        return link.connected ? "Looking for Mac…" : "Not Connected"
    }

    private var subtitle: String {
        switch link.state {
        case .sending: return "Sending…"
        case .receiving: return "Receiving…"
        case .done(let message): return message
        case .failed(let message): return message
        case .idle:
            if link.peerName != nil { return "Choose a folder or drop it here to send." }
            if link.connected { return "Open ThunderSend on the other Mac." }
            return "Connect another Mac with a Thunderbolt cable."
        }
    }

    private var progress: Double? {
        switch link.state {
        case .sending(let p), .receiving(let p): return p
        default: return nil
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Send"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await link.send(url) }
    }
}
