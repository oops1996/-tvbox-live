import Foundation
import Combine

struct LiveLine: Identifiable, Hashable, Codable {
    let url: String
    var headers: [String: String] = [:]
    var id: String { url + headers.keys.sorted().map { "\n" + $0 + ":" + headers[$0]! }.joined() }
}

struct LiveChannel: Identifiable, Hashable, Codable {
    let group: String
    let name: String
    var lines: [LiveLine]
    var url: String { lines.first?.url ?? "" }
    var id: String { group + "\n" + name.lowercased() }

    init(group: String, name: String, url: String) {
        self.group = group; self.name = name; lines = [LiveLine(url: url)]
    }

    enum CodingKeys: String, CodingKey { case group, name, url, lines }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        group = try values.decode(String.self, forKey: .group)
        name = try values.decode(String.self, forKey: .name)
        lines = try values.decodeIfPresent([LiveLine].self, forKey: .lines)
            ?? [LiveLine(url: values.decode(String.self, forKey: .url))]
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(group, forKey: .group); try values.encode(name, forKey: .name)
        try values.encode(url, forKey: .url); try values.encode(lines, forKey: .lines)
    }

}

struct MediaHistory: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let url: String
    let date: Date
}

@MainActor
final class AppModel: ObservableObject {
    @Published var liveChannels: [LiveChannel] = []
    @Published var selectedChannel: LiveChannel?
    @Published private(set) var selectedLineIndex = 0
    @Published private(set) var livePlaybackMessage = ""
    private var attemptedLines = Set<String>()
    private var workingLines: [String: String] = [:]
    private let liveProxy = LiveNetworkProxy()
    private var liveConnectionID = UUID()
    let playback = IPTVPlayer()
    let films: FilmLibrary
    @Published private(set) var isRefreshingLive = false
    @Published private(set) var liveRefreshMessage = "尚未刷新直播源"
    @Published private(set) var liveRefreshFailed = false
    @Published private(set) var liveLastUpdated: Date?
    private var liveRefreshID = UUID()
    private let defaults: UserDefaults
    @Published var statusText = ""
    @Published var favorites: Set<String> = []
    @Published var history: [MediaHistory] = []

    @Published var liveURL: String {
        didSet { defaults.set(liveURL, forKey: "liveURL") }
    }
    @Published var liveUserAgent: String {
        didSet { defaults.set(liveUserAgent, forKey: "liveUserAgent") }
    }
    @Published var liveDirectConnection: Bool {
        didSet {
            defaults.set(liveDirectConnection, forKey: "liveDirectConnection")
            if selectedChannel != nil { switchLiveLine(to: selectedLineIndex) }
        }
    }
    @Published var webDAVBase: String {
        didSet { defaults.set(webDAVBase, forKey: "webDAVBase") }
    }
    @Published var webDAVUser: String {
        didSet { defaults.set(webDAVUser, forKey: "webDAVUser") }
    }
    @Published var webDAVPassword: String {
        didSet { defaults.set(webDAVPassword, forKey: "webDAVPassword") }
    }

    @Published var softwareDecoding: Bool {
        didSet { defaults.set(softwareDecoding, forKey: "softwareDecoding") }
    }
    @Published var networkCache: Double {
        didSet { defaults.set(networkCache, forKey: "networkCache") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        films = FilmLibrary(defaults: defaults)
        softwareDecoding = defaults.object(forKey: "softwareDecoding") as? Bool ?? true
        networkCache = defaults.object(forKey: "networkCache") as? Double ?? 1500
        liveURL = defaults.string(forKey: "liveURL")
            ?? "https://raw.githubusercontent.com/oops1996/-tvbox-live/main/live.txt"
        liveUserAgent = defaults.string(forKey: "liveUserAgent") ?? "okhttp/3.12.13"
        liveDirectConnection = defaults.object(forKey: "liveDirectConnection") as? Bool ?? false
        webDAVBase = defaults.string(forKey: "webDAVBase") ?? "http://192.168.1.14:5244/dav/"
        webDAVUser = defaults.string(forKey: "webDAVUser") ?? ""
        webDAVPassword = defaults.string(forKey: "webDAVPassword") ?? ""

        if let data = defaults.data(forKey: "favorites"),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            favorites = decoded
        }
        if let data = defaults.data(forKey: "history"),
           let decoded = try? JSONDecoder().decode([MediaHistory].self, from: data) {
            history = decoded
        }
        playback.onFailure = { [weak self] url, reason in self?.liveLineFailed(url: url, reason: reason) }
        playback.onStop = { [weak self] in self?.liveConnectionID = UUID() }
        playback.onRetry = { [weak self] in
            guard let self, self.playback.isLive, let channel = self.selectedChannel,
                  channel.lines.indices.contains(self.selectedLineIndex) else { return }
            self.attemptedLines = [channel.lines[self.selectedLineIndex].id]
        }
        playback.onVideoStarted = { [weak self] url in
            guard let self, let channel = self.selectedChannel,
                  self.playback.isLive, channel.lines.indices.contains(self.selectedLineIndex),
                  channel.lines[self.selectedLineIndex].url == url.absoluteString else { return }
            self.workingLines[channel.id] = channel.lines[self.selectedLineIndex].id
            self.livePlaybackMessage = "已连接线路 \(self.selectedLineIndex + 1) / \(channel.lines.count)"
        }
    }

    func loadLive() async {
        let source = liveURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        liveRefreshID = id
        isRefreshingLive = true
        liveRefreshFailed = false
        liveRefreshMessage = "正在重新读取直播源…"
        defer { if liveRefreshID == id { isRefreshingLive = false } }
        do {
            let channels = try await LiveSourceClient.load(from: source)
            guard liveRefreshID == id else { return }
            guard source == liveURL.trimmingCharacters(in: .whitespacesAndNewlines) else {
                liveRefreshMessage = "源地址已更改，请重新导入"
                return
            }
            func keys(_ values: [LiveChannel]) -> Set<String> {
                Set(values.map(\.id))
            }
            let old = keys(liveChannels), new = keys(channels)
            let added = new.subtracting(old).count, removed = old.subtracting(new).count
            let hadPreviousImport = liveLastUpdated != nil
            // Keep legacy URL-based favorites recognizable when a channel's lines change.
            for channel in liveChannels where isFavorite(channel) { favorites.insert("channel:" + channel.id) }
            for channel in channels where isFavorite(channel) { favorites.insert("channel:" + channel.id) }
            if let data = try? JSONEncoder().encode(favorites) { defaults.set(data, forKey: "favorites") }
            liveChannels = channels
            if let selected = selectedChannel {
                let oldLine = selected.lines.indices.contains(selectedLineIndex) ? selected.lines[selectedLineIndex] : nil
                selectedChannel = channels.first { $0.id == selected.id }
                if let channel = selectedChannel {
                    if let index = channel.lines.firstIndex(where: { $0.id == oldLine?.id }) { selectedLineIndex = index }
                    else if playback.isLive, playback.mediaTitle == selected.name { play(channel: channel) }
                } else if playback.isLive, playback.mediaTitle == selected.name {
                    playback.stop(); livePlaybackMessage = "当前频道已从直播源移除"
                }
            }
            liveLastUpdated = Date()
            liveRefreshMessage = hadPreviousImport
                ? "刷新成功：\(channels.count) 个频道，新增 \(added)，移除 \(removed)"
                : "读取成功：\(channels.count) 个频道"
            statusText = liveRefreshMessage
        } catch {
            guard liveRefreshID == id else { return }
            guard source == liveURL.trimmingCharacters(in: .whitespacesAndNewlines) else {
                liveRefreshMessage = "源地址已更改，请重新导入"
                return
            }
            liveRefreshFailed = true
            // Avoid echoing a signed source URL or credentials from transport errors.
            let reason = (error as? LiveSourceError)?.localizedDescription ?? "网络连接失败，请检查网络或源链接"
            liveRefreshMessage = "刷新失败：\(reason)；保留原有 \(liveChannels.count) 个频道"
            statusText = liveRefreshMessage
        }
    }

    func play(channel: LiveChannel, line: Int? = nil) {
        guard !channel.lines.isEmpty else { return }
        selectedChannel = channel
        selectedLineIndex = line.flatMap { channel.lines.indices.contains($0) ? $0 : nil }
            ?? channel.lines.firstIndex(where: { $0.id == workingLines[channel.id] }) ?? 0
        attemptedLines = []
        history.removeAll { item in channel.lines.contains { $0.url == item.url } }
        addHistory(name: channel.name, url: channel.url)
        startLiveLine()
    }

    func switchLiveLine(to index: Int) {
        guard let channel = selectedChannel, channel.lines.indices.contains(index) else { return }
        selectedLineIndex = index; attemptedLines = []; startLiveLine()
    }

    func nextLiveLine() {
        guard let channel = selectedChannel, !channel.lines.isEmpty else { return }
        switchLiveLine(to: (selectedLineIndex + 1) % channel.lines.count)
    }

    private func startLiveLine() {
        guard let channel = selectedChannel, channel.lines.indices.contains(selectedLineIndex),
              let url = URL(string: channel.lines[selectedLineIndex].url) else { return }
        let line = channel.lines[selectedLineIndex]
        var headers = line.headers
        if headers["User-Agent"] == nil, !liveUserAgent.isEmpty,
           !liveUserAgent.contains("\r"), !liveUserAgent.contains("\n") { headers["User-Agent"] = liveUserAgent }
        attemptedLines.insert(line.id)
        livePlaybackMessage = "正在尝试线路 \(selectedLineIndex + 1) / \(channel.lines.count)"
        if liveDirectConnection {
            playback.stop()
            let attempt = UUID(); liveConnectionID = attempt
            livePlaybackMessage = "直播直连：正在尝试线路 \(selectedLineIndex + 1) / \(channel.lines.count)"
            Task { [weak self] in
                guard let self else { return }
                do {
                    let transportURL = try await self.liveProxy.mediaURL(for: url)
                    guard self.liveConnectionID == attempt else { return }
                    self.playback.play(name: channel.name, url: url, headers: headers, isLive: true,
                        softwareDecoding: self.softwareDecoding, cacheMilliseconds: Int(self.networkCache), transportURL: transportURL)
                } catch {
                    guard self.liveConnectionID == attempt else { return }
                    self.livePlaybackMessage = "直播直连连接失败，请检查 Wi-Fi / 以太网或关闭直连重试"
                }
            }
        } else {
            liveConnectionID = UUID()
            playback.play(name: channel.name, url: url, headers: headers, isLive: true,
                          softwareDecoding: softwareDecoding, cacheMilliseconds: Int(networkCache))
        }
    }

    private func liveLineFailed(url: URL, reason: String) {
        guard playback.isLive, let channel = selectedChannel,
              channel.lines.indices.contains(selectedLineIndex),
              channel.lines[selectedLineIndex].url == url.absoluteString else { return }
        let indices = (1...channel.lines.count).map { (selectedLineIndex + $0) % channel.lines.count }
        if let next = indices.first(where: { !attemptedLines.contains(channel.lines[$0].id) }) {
            selectedLineIndex = next
            startLiveLine()
        } else {
            livePlaybackMessage = "已尝试全部 \(channel.lines.count) 条线路：\(reason)"
        }
    }

    func play(name: String, url: String, headers: [String: String], isLive: Bool = false) {
        guard let u = URL(string: url), ["http", "https", "file"].contains(u.scheme?.lowercased() ?? "") else {
            statusText = "播放地址无效"
            return
        }
        if !isLive { selectedChannel = nil; attemptedLines = []; livePlaybackMessage = ""; liveConnectionID = UUID() }
        playback.play(name: name, url: u, headers: headers, isLive: isLive,
                      softwareDecoding: softwareDecoding, cacheMilliseconds: Int(networkCache))
        addHistory(name: name, url: url)
    }

    func play(history item: MediaHistory) {
        if let channel = liveChannels.first(where: { $0.lines.contains { $0.url == item.url } }) {
            play(channel: channel)
        } else {
            selectedChannel = nil
            play(name: item.name, url: item.url, headers: headers(for: item.url))
        }
    }

    // Never attach a WebDAV password to an unrelated IPTV or history URL.
    func headers(for value: String) -> [String: String] {
        guard let url = URL(string: value), let base = URL(string: webDAVBase),
              url.scheme?.lowercased() == base.scheme?.lowercased(),
              url.host?.lowercased() == base.host?.lowercased(), url.port == base.port else { return [:] }
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard url.path == base.path || url.path.hasPrefix(basePath) else { return [:] }
        return authHeader
    }

    func toggleFavorite(_ channel: LiveChannel) {
        if isFavorite(channel) {
            favorites.remove("channel:" + channel.id)
            for line in channel.lines { favorites.remove(line.url) }
        } else { favorites.insert("channel:" + channel.id); favorites.insert(channel.url) }
        if let data = try? JSONEncoder().encode(favorites) {
            defaults.set(data, forKey: "favorites")
        }
    }

    func isFavorite(_ channel: LiveChannel) -> Bool {
        favorites.contains("channel:" + channel.id) || channel.lines.contains { favorites.contains($0.url) }
    }

    private func addHistory(name: String, url: String) {
        history.removeAll { $0.url == url }
        history.insert(MediaHistory(id: UUID(), name: name, url: url, date: Date()), at: 0)
        history = Array(history.prefix(100))
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: "history")
        }
    }

    func clearHistory() {
        history.removeAll()
        defaults.removeObject(forKey: "history")
    }

    var authHeader: [String: String] {
        guard !webDAVUser.isEmpty else { return [:] }
        let token = Data("\(webDAVUser):\(webDAVPassword)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }
}
