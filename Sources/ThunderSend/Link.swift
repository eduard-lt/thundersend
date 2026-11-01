import Foundation
import Network
import SystemConfiguration

enum Direction { case send, receive }

/// The transfer currently running.
struct Transfer: Equatable {
    let direction: Direction
    var name: String
    var total: UInt64 = 0
    var done: UInt64 = 0
    var rate: Double = 0  // bytes per second

    var fraction: Double { Link.fraction(done, total) }
    var secondsLeft: Double? {
        guard rate > 0 else { return nil }
        return Double(total - min(done, total)) / rate
    }
}

/// A finished transfer. Only kept in memory, so history ends when the app quits.
struct Record: Identifiable {
    enum Outcome: Equatable {
        case done, cancelled
        case failed(String)
    }

    let id = UUID()
    let direction: Direction
    let name: String
    let bytes: UInt64
    let seconds: TimeInterval
    let date = Date()
    let outcome: Outcome
    /// What was sent, or where received items ended up.
    let urls: [URL]
}

/// Finds another Mac running ThunderSend over the Thunderbolt Bridge
/// and moves files and folders between them as a tar stream.
@MainActor @Observable
final class Link {
    private(set) var connected = false
    private(set) var peerName: String?
    private(set) var active: Transfer?
    private(set) var history: [Record] = []

    // Host.current() and hostName can block on network lookups, and this runs before the first window.
    private let myName = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
    private let serviceType = "_thundersend._tcp"
    private let queue = DispatchQueue(label: "thundersend")
    private var bridge: NWInterface?
    private var peer: NWEndpoint?
    private var listener: NWListener?
    private var browser: NWBrowser?

    private var activeConn: NWConnection?
    private var activeTar: Process?
    private var abortOutcome: Record.Outcome?
    private var started = Date()
    private var lastTick = Date()
    private var lastDone: UInt64 = 0

    init() {
        // Writing to a tar that already exited must fail, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        useBridge(Self.findBridge())
        // NWPathMonitor never reports the bridge, so check for it directly.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.useBridge(Self.findBridge()) }
        }
    }

    /// Thunderbolt Bridge gets a self-assigned IPv4 address once a cable links two Macs.
    nonisolated static func findBridge() -> NWInterface? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        for ifa in sequence(first: head, next: { $0?.pointee.ifa_next }) {
            guard let ifa = ifa?.pointee, ifa.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("bridge") { return IPv6Address("fe80::1%\(name)")?.interface }
        }
        return nil
    }

    var busy: Bool { active != nil }
    var canSend: Bool { peerName != nil && !busy }

    func cancel() { abort(.cancelled) }

    private func useBridge(_ iface: NWInterface?) {
        guard iface?.name != bridge?.name else { return }
        // A pulled cable stalls TCP instead of failing it, so end the transfer here.
        if let active { abort(.failed("Cable unplugged at \(Int(active.fraction * 100))%")) }
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

    func send(_ urls: [URL]) async {
        guard let first = urls.first, let peer, let bridge, !busy else { return }
        let name = urls.count == 1 ? first.lastPathComponent : "\(urls.count) items"
        let params = NWParameters.tcp
        params.requiredInterface = bridge
        let conn = NWConnection(to: peer, using: params)
        begin(.send, name: name, conn: conn)
        defer { conn.cancel() }
        do {
            try await conn.ready(on: queue)
            let total = await Task.detached { urls.reduce(0) { $0 + Self.size(of: $1) } }.value
            active?.total = total
            try await conn.write(Self.header(total: total, name: name))

            // ponytail: items from different folders with the same name overwrite each other on arrival.
            // The "./" keeps tar from reading names starting with "-" or "@" as options.
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-c"] + urls.flatMap { ["-C", $0.deletingLastPathComponent().path, "./\($0.lastPathComponent)"] }
            let out = Pipe()
            tar.standardOutput = out
            try tar.run()
            activeTar = tar

            var sent: UInt64 = 0
            let reader = out.fileHandleForReading
            while let chunk = try await Task.detached(operation: { try reader.read(upToCount: 1 << 20) }).value,
                  !chunk.isEmpty {
                try await conn.write(chunk)
                sent += UInt64(chunk.count)
                tick(sent)
            }
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw LinkError("Could not read \(name)") }
            try await conn.write(nil, final: true)
            finish(.done, urls: urls)
        } catch {
            finish(failure(error), urls: urls)
        }
    }

    // MARK: Receiving

    private func receive(_ conn: NWConnection) async {
        guard !busy else { conn.cancel(); return }
        begin(.receive, name: "", conn: conn)
        defer { conn.cancel() }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // Extract into a hidden staging folder first, then move into Downloads
        // under a free name so nothing already there gets overwritten.
        let staging = downloads.appendingPathComponent(".thundersend-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try await conn.ready(on: queue)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            guard let header = try await conn.read(exactly: 10) else { throw LinkError("Transfer was cancelled") }
            active?.total = header.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let nameLength = header.suffix(2).reduce(0) { $0 << 8 | Int($1) }
            if nameLength > 0, let name = try await conn.read(exactly: nameLength) {
                active?.name = String(decoding: name, as: UTF8.self)
            }

            // bsdtar refuses absolute paths and ".." entries by default.
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-x", "-C", staging.path]
            let input = Pipe()
            tar.standardInput = input
            try tar.run()
            activeTar = tar

            var received: UInt64 = 0
            var finished = false
            let writer = input.fileHandleForWriting
            while !finished {
                let (data, complete) = try await conn.read()
                if let data, !data.isEmpty {
                    do {
                        try await Task.detached { try writer.write(contentsOf: data) }.value
                    } catch {
                        throw LinkError("Could not save the files. Is the disk full?")
                    }
                    received += UInt64(data.count)
                    tick(received)
                }
                finished = complete
            }
            try writer.close()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw LinkError("Received data was incomplete") }

            var dests: [URL] = []
            for item in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                let dest = Self.freeURL(downloads.appendingPathComponent(item.lastPathComponent))
                try FileManager.default.moveItem(at: item, to: dest)
                dests.append(dest)
            }
            if dests.count == 1 { active?.name = dests[0].lastPathComponent }
            finish(.done, urls: dests)
        } catch {
            finish(failure(error), urls: [])
        }
    }

    // MARK: Transfer bookkeeping

    private func begin(_ direction: Direction, name: String, conn: NWConnection) {
        active = Transfer(direction: direction, name: name)
        activeConn = conn
        started = Date()
        lastTick = started
        lastDone = 0
    }

    /// Updates progress a few times a second, not once per chunk.
    private func tick(_ done: UInt64) {
        let elapsed = Date().timeIntervalSince(lastTick)
        guard elapsed >= 0.25 else { return }
        let rate = Double(done - lastDone) / elapsed
        let previous = active?.rate ?? 0
        active?.rate = previous == 0 ? rate : previous * 0.7 + rate * 0.3
        active?.done = done
        lastTick = Date()
        lastDone = done
    }

    private func abort(_ outcome: Record.Outcome) {
        abortOutcome = outcome
        // A force cancel resets the connection, so the other Mac sees an error and not a clean end.
        activeConn?.forceCancel()
        if activeTar?.isRunning == true { activeTar?.terminate() }
    }

    private func failure(_ error: Error) -> Record.Outcome {
        if let abortOutcome { return abortOutcome }
        if error is LinkError { return .failed(error.localizedDescription) }
        if error is NWError {
            let percent = Int((active?.fraction ?? 0) * 100)
            return .failed(percent == 0 ? "Could not reach the other Mac" : "Connection lost at \(percent)%")
        }
        return .failed(error.localizedDescription)
    }

    private func finish(_ outcome: Record.Outcome, urls: [URL]) {
        if let tar = activeTar, tar.isRunning {
            tar.terminate()
            tar.waitUntilExit()
        }
        if let active {
            history.insert(Record(direction: active.direction,
                                  name: active.name.isEmpty ? "Incoming transfer" : active.name,
                                  bytes: active.total,
                                  seconds: Date().timeIntervalSince(started),
                                  outcome: outcome,
                                  urls: urls), at: 0)
        }
        active = nil
        activeConn = nil
        activeTar = nil
        abortOutcome = nil
    }

    // MARK: Helpers

    /// Total size, then the name to show on the other Mac, both length-prefixed in big endian.
    nonisolated static func header(total: UInt64, name: String) -> Data {
        let name = Data(name.utf8.prefix(1024))
        return withUnsafeBytes(of: total.bigEndian) { Data($0) }
            + withUnsafeBytes(of: UInt16(name.count).bigEndian) { Data($0) }
            + name
    }

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
