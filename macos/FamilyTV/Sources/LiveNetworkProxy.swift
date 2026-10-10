import Foundation
@preconcurrency import Network

/// A loopback-only HLS transport for live requests. Outgoing sockets bind to
/// Wi-Fi/Ethernet; HTTPS uses Network TLS with its normal certificate validation.
/// No system routes, VPN configuration or credentials are changed or persisted.
final class LiveNetworkProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "familytv.live-direct")
    private var monitor: NWPathMonitor?
    private var listener: NWListener?
    private var interface: NWInterface?
    private var readyURL: String?
    private var waiting: [CheckedContinuation<String, Error>] = []
    private let token = UUID().uuidString
    private var connections: [UUID: LiveProxyConnection] = [:]

    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "没有可用的 Wi-Fi / 以太网直连，请检查本机网络" }
    }

    func mediaURL(for url: URL) async throws -> URL {
        let endpoint = try await endpoint()
        return Self.wrap(url, endpoint: endpoint)
    }

    static func wrap(_ url: URL, endpoint: String) -> URL {
        let value = Data(url.absoluteString.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: endpoint + "/" + value)!
    }

    private func endpoint() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let readyURL { continuation.resume(returning: readyURL); return }
                waiting.append(continuation)
                guard monitor == nil, listener == nil else { return }
                let pathMonitor = NWPathMonitor()
                monitor = pathMonitor
                pathMonitor.pathUpdateHandler = { [weak self] path in
                    guard let self else { return }
                    self.monitor?.cancel(); self.monitor = nil
                    let physical = path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }
                    guard let selected = physical.first(where: { $0.type == .wifi }) ?? physical.first else {
                        self.complete(.failure(Failure.unavailable)); return
                    }
                    self.interface = selected
                    self.startListener()
                }
                pathMonitor.start(queue: queue)
            }
        }
    }

    private func startListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let next = try NWListener(using: parameters)
            listener = next
            next.stateUpdateHandler = { [weak self, weak next] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = next?.port else { self.complete(.failure(Failure.unavailable)); return }
                    self.readyURL = "http://127.0.0.1:\(port.rawValue)/direct/\(self.token)"
                    self.complete(.success(self.readyURL!))
                case .failed(let error): self.complete(.failure(error))
                default: break
                }
            }
            next.newConnectionHandler = { [weak self] client in
                guard let self, let interface = self.interface else { client.cancel(); return }
                let id = UUID()
                let connection = LiveProxyConnection(client: client, interface: interface, queue: self.queue, endpoint: self.readyURL!) { [weak self] in
                    self?.connections.removeValue(forKey: id)
                }
                self.connections[id] = connection
                connection.start()
            }
            next.start(queue: queue)
        } catch { complete(.failure(error)) }
    }

    private func complete(_ result: Result<String, Error>) {
        let callbacks = waiting; waiting = []
        if case .failure = result { listener?.cancel(); listener = nil; readyURL = nil }
        for callback in callbacks { callback.resume(with: result) }
    }
}

private final class LiveProxyConnection {
    private let client: NWConnection
    private let interface: NWInterface
    private let queue: DispatchQueue
    private let endpoint: String
    private let onFinish: () -> Void
    private var server: NWConnection?
    private var buffer = Data()
    private var finished = false
    private var origin: URL?
    private var responseLines: [String] = []
    private var playlistBody = Data()
    private var chunked = false
    private var expectedLength: Int?
    private var idleTimeout: DispatchWorkItem?

    init(client: NWConnection, interface: NWInterface, queue: DispatchQueue, endpoint: String, onFinish: @escaping () -> Void) {
        self.client = client; self.interface = interface; self.queue = queue
        self.endpoint = endpoint; self.onFinish = onFinish
    }

    func start() {
        touch()
        client.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.readRequest() }
            if case .failed = state { self.finish() }
        }
        client.start(queue: queue)
    }

    private func readRequest() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let data { self.touch(); self.buffer.append(data) }
            guard self.buffer.count <= 65_536 else { self.reject(431); return }
            if let separator = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.connect(header: Data(self.buffer[..<separator.lowerBound]))
                self.buffer = Data()
            } else if complete || error != nil { self.finish() }
            else { self.readRequest() }
        }
    }

    private func connect(header: Data) {
        guard let text = String(data: header, encoding: .isoLatin1) else { reject(400); return }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ").map(String.init)
        let prefix = URL(string: endpoint)!.path + "/"
        guard first.count == 3, ["GET", "HEAD"].contains(first[0]), first[1].hasPrefix(prefix) else { reject(400); return }
        var encoded = String(first[1].dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let address = String(data: data, encoding: .utf8),
              let url = URL(string: address), ["http", "https"].contains(url.scheme), let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? (url.scheme == "https" ? 443 : 80)) ?? 0),
              port.rawValue > 0, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { reject(400); return }
        origin = url
        var path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { path += "?" + query }
        var forwarded = ["\(first[0]) \(path) \(first[2])", "Host: \(host.contains(":") ? "[" + host + "]" : host)\(url.port.map { ":\($0)" } ?? "")"]
        forwarded += lines.dropFirst().filter {
            let key = $0.split(separator: ":", maxSplits: 1).first?.lowercased() ?? ""
            return !["host", "connection", "proxy-connection", "proxy-authorization", "accept-encoding"].contains(key)
        }
        forwarded += ["Connection: close", "Accept-Encoding: identity"]
        let request = Data((forwarded.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        let parameters = url.scheme == "https" ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()) : NWParameters.tcp
        if host != "localhost", host != "::1", !host.hasPrefix("127.") { parameters.requiredInterface = interface }
        let remote = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        server = remote
        remote.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                self.touch()
                remote.send(content: request, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil { self.reject(502) } else { self.readResponse() }
                })
            case .failed: self.reject(502)
            default: break
            }
        }
        remote.start(queue: queue)
    }

    private func readResponse() {
        server?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let data { self.touch(); self.buffer.append(data) }
            if let separator = self.buffer.range(of: Data("\r\n\r\n".utf8)), let origin = self.origin,
               let text = String(data: self.buffer[..<separator.lowerBound], encoding: .isoLatin1) {
                self.responseLines = text.components(separatedBy: "\r\n")
                let status = self.responseLines[0].split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
                let body = Data(self.buffer[separator.upperBound...]); self.buffer = Data()
                let type = self.header("content-type")?.lowercased() ?? ""
                let playlist = (200..<300).contains(status) && (type.contains("mpegurl") || origin.path.lowercased().hasSuffix(".m3u8"))
                self.responseLines = self.responseLines.map { line in
                    guard line.lowercased().hasPrefix("location:"), let destination = URL(string: String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces), relativeTo: origin)?.absoluteURL,
                          ["http", "https"].contains(destination.scheme) else { return line }
                    return "Location: " + LiveNetworkProxy.wrap(destination, endpoint: self.endpoint).absoluteString
                }
                if playlist {
                    self.chunked = self.header("transfer-encoding")?.lowercased().contains("chunked") == true
                    self.expectedLength = self.header("content-length").flatMap(Int.init)
                    self.playlistBody = body
                    self.readPlaylist(complete: complete)
                } else {
                    let packet = Data((self.responseLines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
                    self.client.send(content: packet, isComplete: complete, completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if complete || error != nil { self.finish() } else { self.relayResponse() }
                    })
                }
            } else if complete || error != nil || self.buffer.count > 65_536 { self.reject(502) }
            else { self.readResponse() }
        }
    }

    private func header(_ name: String) -> String? {
        responseLines.first(where: { $0.lowercased().hasPrefix(name + ":") }).map {
            String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
        }
    }

    private func readPlaylist(complete: Bool) {
        guard playlistBody.count <= 2_097_152 else { reject(502); return }
        if complete || (!chunked && expectedLength.map { playlistBody.count >= $0 } == true) {
            let body = chunked ? Self.unchunk(playlistBody) : playlistBody
            guard let body, let text = String(data: body, encoding: .utf8), let origin else { reject(502); return }
            let rewritten = Self.rewrite(text, origin: origin, endpoint: endpoint)
            let payload = Data(rewritten.utf8)
            let headers = responseLines.filter { line in
                let key = line.split(separator: ":", maxSplits: 1).first?.lowercased() ?? ""
                return !["content-length", "transfer-encoding", "content-encoding", "connection"].contains(key)
            } + ["Content-Length: \(payload.count)", "Connection: close"]
            client.send(content: Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + payload, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.finish() })
        } else {
            server?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
                guard let self, !self.finished else { return }
                if let data { self.touch(); self.playlistBody.append(data) }
                if error != nil { self.reject(502) } else { self.readPlaylist(complete: complete) }
            }
        }
    }

    static func rewrite(_ text: String, origin: URL, endpoint: String) -> String {
        func wrap(_ value: String) -> String {
            guard let url = URL(string: value, relativeTo: origin)?.absoluteURL, ["http", "https"].contains(url.scheme) else { return value }
            return LiveNetworkProxy.wrap(url, endpoint: endpoint).absoluteString
        }
        let expression = try! NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
        return text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return line }
            if !trimmed.hasPrefix("#") { return wrap(trimmed) }
            var result = line
            for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let range = Range(match.range(at: 1), in: result) else { continue }
                result.replaceSubrange(range, with: wrap(String(result[range])))
            }
            return result
        }.joined(separator: "\n")
    }

    private static func unchunk(_ input: Data) -> Data? {
        var cursor = input.startIndex, output = Data()
        let crlf = Data("\r\n".utf8)
        while cursor < input.endIndex {
            guard let range = input[cursor...].range(of: crlf), let line = String(data: input[cursor..<range.lowerBound], encoding: .ascii),
                  let size = Int(line.split(separator: ";").first ?? "", radix: 16), size >= 0 else { return nil }
            cursor = range.upperBound
            if size == 0 { return output }
            guard size <= input.endIndex - cursor - 2 else { return nil }
            output.append(input[cursor..<(cursor + size)]); cursor += size
            guard input[cursor..<(cursor + 2)] == crlf else { return nil }; cursor += 2
        }
        return nil
    }

    private func relayResponse() {
        server?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if data != nil { self.touch() }
            if error != nil { self.finish(); return }
            self.client.send(content: data, isComplete: complete, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if complete || error != nil { self.finish() } else { self.relayResponse() }
            })
        }
    }

    private func reject(_ code: Int) {
        client.send(content: Data("HTTP/1.1 \(code) Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8), isComplete: true,
                    completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        idleTimeout?.cancel(); idleTimeout = nil
        client.cancel(); server?.cancel(); onFinish()
    }

    private func touch() {
        idleTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.finish() }
        idleTimeout = timeout
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)
    }
}
