import AppKit
import SwiftUI

@main
struct ThunderSendApp: App {
    @State private var link = Link()

    var body: some Scene {
        Window("ThunderSend", id: "main") {
            ContentView(link: link)
                .frame(width: 420, height: 600)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

// MARK: Colors and formatting

private func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
    func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    return Color(nsColor: NSColor(name: nil) { appearance in
        color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
    })
}

private let accent = adaptive(0x2F5BEA, 0x3D68F2)
private let accentText = adaptive(0x2448C8, 0xAFC2FF)
private let successText = adaptive(0x176B3F, 0x6FD6A1)
private let failureText = adaptive(0xA8251A, 0xFF9C8F)

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

private func formatSeconds(_ seconds: Double) -> String {
    seconds < 60 ? "\(max(1, Int(seconds.rounded()))) sec" : "\(Int((seconds / 60).rounded())) min"
}

// MARK: Window

struct ContentView: View {
    let link: Link
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            ConnectionStrip(link: link)
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 16)

            card
                .frame(height: 226)
                .padding(.horizontal, 16)

            HistoryList(link: link)
                .padding(.top, 14)

            HStack {
                Spacer()
                // SwiftUI's name, because this app has its own Link class.
                SwiftUI.Link(destination: URL(string: "https://ko-fi.com/eduardolteanu")!) {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Buy me a coffee")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard link.canSend, !urls.isEmpty else { return false }
            Task { await link.send(urls) }
            return true
        } isTargeted: { targeted = $0 && link.canSend }
    }

    @ViewBuilder private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        if let transfer = link.active {
            TransferCard(transfer: transfer, peer: link.peerName ?? "the other Mac", cancel: link.cancel)
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.separator))
        } else if link.peerName == nil {
            WaitingCard(connected: link.connected)
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.separator))
        } else {
            DropCard(targeted: targeted, choose: choose)
                .background(targeted ? accent.opacity(0.12) : .clear, in: shape)
                .overlay(
                    shape.strokeBorder(targeted ? accent : Color.secondary.opacity(0.6),
                                       style: StrokeStyle(lineWidth: 2, dash: targeted ? [] : [6, 5]))
                )
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Task { await link.send(panel.urls) }
    }
}

// MARK: Connection strip

struct ConnectionStrip: View {
    let link: Link

    var body: some View {
        let linked = link.peerName != nil
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                device("This Mac")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                HStack(spacing: 6) {
                    cable(linked)
                    Image(systemName: "bolt.fill")
                        .symbolEffect(.pulse, isActive: link.connected && !linked)
                    cable(linked)
                }
                .foregroundStyle(linked ? accentText : Color.secondary)
                device(link.peerName ?? "Other Mac")
                    .foregroundStyle(linked ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func device(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer")
            Text(name).lineLimit(1).truncationMode(.middle)
        }
        .font(.callout.weight(.medium))
    }

    private func cable(_ linked: Bool) -> some View {
        Rectangle()
            .stroke(style: StrokeStyle(lineWidth: 2, dash: linked ? [] : [3, 3]))
            .frame(width: 22, height: 1)
    }

    private var status: String {
        if link.peerName != nil { return "Connected over Thunderbolt" }
        return link.connected ? "Cable found. Open ThunderSend on the other Mac." : "Waiting for a cable"
    }
}

// MARK: Main card

struct DropCard: View {
    let targeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(accentText)
            Text(targeted ? "Let go to send" : "Drop anything here to send")
                .font(.headline)
                .padding(.top, 4)
            Text("They land in Downloads on the other Mac")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose Files or Folders…", action: choose)
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.large)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WaitingCard: View {
    let connected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect the other Mac").font(.headline)
            step(1, "Plug in a Thunderbolt or USB4 cable.", done: connected)
            step(2, "Open ThunderSend on that Mac too. They find each other on their own.", done: false)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func step(_ number: Int, _ text: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.12))
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold))
                } else {
                    Text("\(number)").font(.caption.weight(.semibold))
                }
            }
            .frame(width: 22, height: 22)
            .foregroundStyle(accentText)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }
}

struct TransferCard: View {
    let transfer: Transfer
    let peer: String
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(transfer.direction == .send ? "Sending to \(peer)" : "Receiving from \(peer)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accentText)
            Text(transfer.name.isEmpty ? "Getting ready…" : transfer.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: transfer.fraction)
                .tint(accent)
            HStack {
                Text("\(formatBytes(min(transfer.done, transfer.total))) of \(formatBytes(transfer.total))")
                Spacer()
                if let left = transfer.secondsLeft {
                    Text("\(formatBytes(UInt64(transfer.rate)))/s, \(formatSeconds(left)) left")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            Button("Cancel", action: cancel)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: History

struct HistoryList: View {
    let link: Link

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("This session").font(.caption.weight(.semibold))
                Spacer()
                Text("Clears when you quit").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            if link.history.isEmpty {
                Text("Nothing moved yet. Your transfers will show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(link.history) { HistoryRow(record: $0, link: link) }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HistoryRow: View {
    let record: Record
    let link: Link

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(failed ? failureText : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            action
        }
        .padding(.leading, 8)
        .frame(height: 52)
    }

    private var failed: Bool { record.outcome != .done }

    private var icon: String {
        if failed { return "xmark" }
        return record.direction == .send ? "arrow.up" : "arrow.down"
    }

    private var tint: Color {
        if failed { return failureText }
        return record.direction == .send ? accentText : successText
    }

    private var detail: String {
        let time = record.date.formatted(date: .omitted, time: .shortened)
        switch record.outcome {
        case .done:
            let verb = record.direction == .send ? "Sent" : "Received"
            return "\(verb) · \(formatBytes(record.bytes)) in \(formatSeconds(record.seconds)) · \(time)"
        case .cancelled:
            return "Cancelled · \(time)"
        case .failed(let reason):
            return "\(reason) · \(time)"
        }
    }

    /// Sent items can go again. Received items can be shown. A failed receive has nothing to act on.
    @ViewBuilder private var action: some View {
        if record.direction == .send {
            rowButton(failed ? "Try \(record.name) Again" : "Send \(record.name) Again", "arrow.clockwise") {
                Task { await link.send(record.urls) }
            }
            .disabled(!link.canSend)
        } else if !record.urls.isEmpty {
            rowButton("Show \(record.name) in Finder", "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting(record.urls)
            }
        }
    }

    private func rowButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
    }
}
