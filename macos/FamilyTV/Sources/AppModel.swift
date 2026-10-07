import Foundation
import AVKit

struct LiveChannel: Identifiable, Hashable, Codable {
    let id = UUID()
    let group: String
    let name: String
    let url: String

    enum CodingKeys: String, CodingKey { case group, name, url }
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
    @Published var player: AVPlayer?
    @Published var statusText = ""
    @Published var favorites: Set<String> = []
    @Published var history: [MediaHistory] = []

    @Published var liveURL: String {
        didSet { UserDefaults.standard.set(liveURL, forKey: "liveURL") }
    }
    @Published var webDAVBase: String {
        didSet { UserDefaults.standard.set(webDAVBase, forKey: "webDAVBase") }
    }
    @Published var webDAVUser: String {
        didSet { UserDefaults.standard.set(webDAVUser, forKey: "webDAVUser") }
    }
    @Published var webDAVPassword: String {
        didSet { UserDefaults.standard.set(webDAVPassword, forKey: "webDAVPassword") }
    }

    init() {
        liveURL = UserDefaults.standard.string(forKey: "liveURL")
            ?? "https://cdn.jsdelivr.net/gh/oops1996/-tvbox-live@main/live.txt"
        webDAVBase = UserDefaults.standard.string(forKey: "webDAVBase") ?? "http://192.168.1.14:5244/dav/"
        webDAVUser = UserDefaults.standard.string(forKey: "webDAVUser") ?? ""
        webDAVPassword = UserDefaults.standard.string(forKey: "webDAVPassword") ?? ""

        if let data = UserDefaults.standard.data(forKey: "favorites"),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            favorites = decoded
        }
        if let data = UserDefaults.standard.data(forKey: "history"),
           let decoded = try? JSONDecoder().decode([MediaHistory].self, from: data) {
            history = decoded
        }
    }

    func loadLive() async {
        guard let url = URL(string: liveURL) else {
            statusText = "直播地址无效"
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else {
                statusText = "直播源编码无法识别"
                return
            }
            var group = "直播"
            var channels: [LiveChannel] = []
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                let parts = line.split(separator: ",", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[1] == "#genre#" {
                    group = parts[0]
                } else if parts[1].hasPrefix("http") {
                    channels.append(LiveChannel(group: group, name: parts[0], url: parts[1]))
                }
            }
            liveChannels = channels
            statusText = channels.isEmpty ? "没有读取到直播频道" : "已载入 \(channels.count) 个频道"
        } catch {
            statusText = "直播源加载失败：\(error.localizedDescription)"
        }
    }

    func play(channel: LiveChannel) {
        selectedChannel = channel
        play(name: channel.name, url: channel.url, headers: [:])
    }

    func play(name: String, url: String, headers: [String: String]) {
        guard let u = URL(string: url) else { return }
        let asset = AVURLAsset(url: u, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player?.play()
        addHistory(name: name, url: url)
    }

    func toggleFavorite(_ channel: LiveChannel) {
        if favorites.contains(channel.url) { favorites.remove(channel.url) }
        else { favorites.insert(channel.url) }
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: "favorites")
        }
    }

    private func addHistory(name: String, url: String) {
        history.removeAll { $0.url == url }
        history.insert(MediaHistory(id: UUID(), name: name, url: url, date: Date()), at: 0)
        history = Array(history.prefix(100))
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "history")
        }
    }

    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: "history")
    }

    var authHeader: [String: String] {
        guard !webDAVUser.isEmpty else { return [:] }
        let token = Data("\(webDAVUser):\(webDAVPassword)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }
}
