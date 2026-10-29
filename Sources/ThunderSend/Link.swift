import Foundation
import Network

/// Finds another Mac running ThunderSend over the Thunderbolt Bridge
/// and moves folders between them as a tar stream.
@MainActor @Observable
final class Link {
    enum State: Equatable {
        case idle
        case sending(Double)
        case receiving(Double)
        case done(String)
        case failed(String)
    }

    private(set) var connected = false
    private(set) var peerName: String?
    private(set) var state: State = .idle

    private let myName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    private let serviceType = "_thundersend._tcp"
    private let queue = DispatchQueue(label: "thundersend")
    private let monitor = NWPathMonitor()
    private var bridge: NWInterface?
    private var peer: NWEndpoint?
    private var listener: NWListener?
    private var browser: NWBrowser?

    init() {
        // Thunderbolt Bridge shows up as "bridge0" once a cable links two Macs.
        monitor.pathUpdateHandler = { [weak self] path in
            let iface = path.availableInterfaces.first { $0.name.hasPrefix("bridge") }
            Task { @MainActor in self?.useBridge(iface) }
        }
        monitor.start(queue: queue)
    }

    var busy: Bool {
        switch state {
        case .sending, .receiving: true
        default: false
        }
    }

    private func useBridge(_ iface: NWInterface?) {
        guard iface?.name != bridge?.name else { return }
        bridge = iface
        connected = iface != nil
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        peer = nil
        peerName = nil
        guard let iface else { return }

        // Both listening and browsing are pinned to the bridge, so nothing
        // is ever sent or accepted over Wi-Fi or Ethernet.
        let params = NWParameters.tcp
        params.requiredInterface = iface

        if let l = try? NWListener(using: params) {
            l.service = NWListener.Service(name: myName, type: serviceType)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in await self?.receive(conn) }
            }
            l.start(queue: queue)
            listener = l
        }

        let b = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
        let me = myName
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let other = results.lazy.compactMap { r -> (NWEndpoint, String)? in
                guard case let .service(name, _, _, _) = r.endpoint, name != me else { return nil }
                return (r.endpoint, name)
            }.first
            Task { @MainActor in
                self?.peer = other?.0
                self?.peerName = other?.1
            }
        }
        b.start(queue: queue)
        browser = b
    }

    // MARK: Sending

    func send(_ url: URL) async {
        guard let peer, let bridge, !busy else { return }
        state = .sending(0)
        let params = NWParameters.tcp
        params.requiredInterface = bridge
        let conn = NWConnection(to: peer, using: params)
        defer { conn.cancel() }
        do {
            try await conn.ready(on: queue)
            let total = Self.size(of: url)
            try await conn.write(withUnsafeBytes(of: total.bigEndian) { Data($0) })

            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-c", "-C", url.deletingLastPathComponent().path, url.lastPathComponent]
            let out = Pipe()
            tar.standardOutput = out
            try tar.run()

            var sent: UInt64 = 0
            let reader = out.fileHandleForReading
            while let chunk = try await Task.detached(operation: { try reader.read(upToCount: 1 << 20) }).value,
                  !chunk.isEmpty {
                try await conn.write(chunk)
                sent += UInt64(chunk.count)
                state = .sending(Self.fraction(sent, total))
            }
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw LinkError("Could not read \(url.lastPathComponent)") }
            try await conn.write(nil, final: true)
            state = .done("Sent \(url.lastPathComponent)")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Receiving

    private func receive(_ conn: NWConnection) async {
        guard !busy else { conn.cancel(); return }
        state = .receiving(0)
        defer { conn.cancel() }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // Extract into a hidden staging folder first, then move into Downloads
        // under a free name so nothing already there gets overwritten.
        let staging = downloads.appendingPathComponent(".thundersend-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try await conn.ready(on: queue)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            guard let header = try await conn.read(exactly: 8) else { throw LinkError("Transfer was cancelled") }
            let total = header.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }

            // bsdtar refuses absolute paths and ".." entries by default.
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-x", "-C", staging.path]
            let input = Pipe()
            tar.standardInput = input
            try tar.run()

            var received: UInt64 = 0
            var finished = false
            while !finished {
                let (data, complete) = try await conn.read()
                if let data, !data.isEmpty {
                    try input.fileHandleForWriting.write(contentsOf: data)
                    received += UInt64(data.count)
                    state = .receiving(Self.fraction(received, total))
                }
                finished = complete
            }
            try input.fileHandleForWriting.close()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw LinkError("Received data was incomplete") }

            var names: [String] = []
            for item in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                let dest = Self.freeURL(downloads.appendingPathComponent(item.lastPathComponent))
                try FileManager.default.moveItem(at: item, to: dest)
                names.append(dest.lastPathComponent)
            }
            state = .done("Received \(names.joined(separator: ", ")) in Downloads")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Helpers

    nonisolated static func fraction(_ done: UInt64, _ total: UInt64) -> Double {
        // tar adds headers, so the stream runs slightly past the raw file size.
        total == 0 ? 0 : min(Double(done) / Double(total), 1)
    }

    nonisolated static func size(of url: URL) -> UInt64 {
        func bytes(_ u: URL) -> UInt64 {
            UInt64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total = bytes(url)
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let item = items?.nextObject() as? URL { total += bytes(item) }
        return total
    }

    nonisolated static func freeURL(_ url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            n += 1
        }
        return candidate
    }
}

struct LinkError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: Async wrappers for NWConnection

extension NWConnection {
    func ready(on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Stop listening after the first answer so the continuation resumes once.
            stateUpdateHandler = { [unowned self] state in
                switch state {
                case .ready:
                    stateUpdateHandler = nil
                    cont.resume()
                case .failed(let error), .waiting(let error):
                    stateUpdateHandler = nil
                    cont.resume(throwing: error)
                case .cancelled:
                    stateUpdateHandler = nil
                    cont.resume(throwing: LinkError("Connection closed"))
                default:
                    break
                }
            }
            if state == .setup { start(queue: queue) }
        }
    }

    func write(_ data: Data?, final: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: final,
                 completion: .contentProcessed { error in
                     if let error { cont.resume(throwing: error) } else { cont.resume() }
                 })
        }
    }

    func read(exactly length: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: data) }
            }
        }
    }

    func read() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { cont in
            receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: (data, complete)) }
            }
        }
    }
}
