import Foundation

enum LiveSourceError: LocalizedError {
    case invalidURL, http(Int), encoding, format
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入完整的 HTTP 或 HTTPS 直播源链接"
        case .http(let code): return "直播源返回 HTTP \(code)"
        case .encoding: return "直播源不是 UTF-8 文本"
        case .format: return "没有识别到直播列表，请检查源链接是否返回 TXT 或 M3U"
        }
    }
}

enum LiveSourceClient {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func sourceURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { throw LiveSourceError.invalidURL }
        return url
    }

    static func originURL(_ url: URL) -> URL {
        // Mutable jsDelivr GitHub branches can lag behind their original file.
        // Preserve custom, signed, authenticated and version-pinned URLs exactly.
        guard url.host?.lowercased() == "cdn.jsdelivr.net", url.scheme == "https",
              url.user == nil, url.password == nil, url.query == nil else { return url }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "gh" else { return url }
        let repository = parts[2].split(separator: "@", maxSplits: 1).map(String.init)
        guard repository.count == 2, ["main", "master"].contains(repository[1]) else { return url }
        var result = URL(string: "https://raw.githubusercontent.com")!
        for part in [parts[1], repository[0], repository[1]] + Array(parts.dropFirst(3)) {
            result.appendPathComponent(part)
        }
        return result
    }

    static func load(from value: String) async throws -> [LiveChannel] {
        let original = try sourceURL(value)
        var url = originURL(original)
        if url.host == "raw.githubusercontent.com", url.user == nil, url.query == nil {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "_familytv_refresh", value: UUID().uuidString)]
            url = components.url!
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveSourceError.format }
        guard (200..<300).contains(http.statusCode) else { throw LiveSourceError.http(http.statusCode) }
        guard let text = String(data: data, encoding: .utf8) else { throw LiveSourceError.encoding }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> [LiveChannel] {
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var group = "直播", pendingName: String?, pendingGroup = "直播"
        var pendingHeaders: [String: String] = [:]
        var channels: [LiveChannel] = [], recognized = false
        var indices: [String: Int] = [:]
        func append(_ name: String, _ address: String, _ category: String, headers: [String: String] = [:]) {
            let parts = address.components(separatedBy: "|")
            guard !name.isEmpty, let url = try? sourceURL(parts[0]) else { return }
            var headers = headers
            if parts.count > 1, let items = URLComponents(string: "https://headers.invalid/?" + parts.dropFirst().joined(separator: "|"))?.queryItems {
                for item in items {
                    if let key = headerName(item.name), let value = item.value, !value.contains("\r"), !value.contains("\n") {
                        headers[key] = value
                    }
                }
            }
            let line = LiveLine(url: url.absoluteString, headers: headers)
            let key = category + "\n" + name.lowercased()
            if let index = indices[key] {
                if !channels[index].lines.contains(where: { $0.id == line.id }) { channels[index].lines.append(line) }
            } else {
                indices[key] = channels.count
                var channel = LiveChannel(group: category, name: name, url: url.absoluteString)
                channel.lines = [line]; channels.append(channel)
            }
        }
        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXTM3U") { recognized = true; continue }
            if line.hasPrefix("#EXTINF:") {
                recognized = true
                pendingName = nil
                pendingHeaders = [:]
                var quoted = false
                for index in line.indices {
                    if line[index] == "\"" { quoted.toggle() }
                    else if line[index] == ",", !quoted {
                        pendingName = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
                if let range = line.range(of: "group-title=\""),
                   let end = line[range.upperBound...].firstIndex(of: "\"") {
                    pendingGroup = String(line[range.upperBound..<end])
                } else { pendingGroup = "直播" }
                continue
            }
            if line.hasPrefix("#EXTVLCOPT:"), pendingName != nil {
                let parts = line.dropFirst(11).split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, let key = headerName(parts[0]) { pendingHeaders[key] = parts[1] }
                continue
            }
            if line.hasPrefix("#EXTGRP:"), pendingName != nil {
                pendingGroup = String(line.dropFirst(8)); continue
            }
            if line.hasPrefix("#") { continue }
            if let name = pendingName {
                append(name, line, pendingGroup, headers: pendingHeaders)
                pendingName = nil; pendingHeaders = [:]; continue
            }
            let parts = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[1] == "#genre#" { recognized = true; group = parts[0] }
            else if (try? sourceURL(parts[1])) != nil { recognized = true; append(parts[0], parts[1], group) }
        }
        // A successfully retrieved empty playlist is authoritative (all channels removed).
        guard recognized || lines.allSatisfy(\.isEmpty) else { throw LiveSourceError.format }
        return channels
    }

    private static func headerName(_ value: String) -> String? {
        switch value.lowercased() {
        case "user-agent", "http-user-agent": return "User-Agent"
        case "referer", "referrer", "http-referrer": return "Referer"
        default: return nil
        }
    }

    static func displayName(_ value: String) -> String {
        guard let url = try? sourceURL(value) else { return "未设置有效链接" }
        return (url.host ?? "直播源") + (url.lastPathComponent.isEmpty ? "" : "/" + url.lastPathComponent)
    }
}
