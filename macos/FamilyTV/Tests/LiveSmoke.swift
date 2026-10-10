import Foundation

// The refresh model is exercised without a GPU or changing real user preferences.
@MainActor final class IPTVPlayer {
    var isLive = false, mediaTitle = "", stopped = false
    var currentURL: URL?, currentHeaders: [String: String] = [:]
    var onFailure: ((URL, String) -> Void)?
    var onVideoStarted: ((URL) -> Void)?
    var onRetry: (() -> Void)?
    var onStop: (() -> Void)?
    func play(name: String, url: URL, headers: [String: String], isLive: Bool, softwareDecoding: Bool, cacheMilliseconds: Int, transportURL: URL? = nil) {
        self.isLive = isLive; mediaTitle = name; stopped = false
        currentURL = url; currentHeaders = headers
    }
    func stop() { stopped = true }
}
@MainActor final class FilmLibrary { init(defaults: UserDefaults) {} }
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func removeObject(forKey key: String) { values[key] = nil }
}

@main struct LiveSmoke {
    enum Failure: Error { case check(String) }
    static func check(_ condition: @autoclosure () -> Bool, _ text: String) throws {
        if !condition() { throw Failure.check(text) }
    }
    static func control(_ base: String, _ path: String) async throws {
        let (_, response) = try await LiveSourceClient.session.data(for: URLRequest(url: URL(string: base + path)!, cachePolicy: .reloadIgnoringLocalCacheData))
        try check((response as? HTTPURLResponse)?.statusCode == 200, "Fixture control failed")
    }
    @MainActor static func main() async {
        do {
            let base = CommandLine.arguments[1]
            let defaults = MemoryDefaults()
            defaults.set(base + "/live.txt", forKey: "liveURL")
            let model = AppModel(defaults: defaults)
            await model.loadLive()
            try check(model.liveChannels.map(\.name) == ["甲", "乙"] && model.liveLastUpdated != nil, "Initial import failed")
            model.play(channel: model.liveChannels[0])
            model.toggleFavorite(model.liveChannels[0])
            let firstDate = model.liveLastUpdated
            try await control(base, "/set/updated")
            await model.loadLive()
            try check(model.liveChannels.map(\.name) == ["乙", "丙"], "Cached or deleted channel survived refresh")
            try check(model.liveRefreshMessage.contains("新增 1，移除 1"), "Change counts wrong")
            try check(model.selectedChannel == nil && model.playback.stopped, "Removed playing channel stayed selected")
            try check(model.favorites.contains("https://example.com/a.m3u8") && model.history.count == 1, "Refresh erased favorites/history")
            try check(model.liveLastUpdated! >= firstDate!, "Successful timestamp missing")
            let goodDate = model.liveLastUpdated
            for revision in ["http-error", "html", "encoding"] {
                try await control(base, "/set/" + revision)
                await model.loadLive()
                try check(model.liveChannels.map(\.name) == ["乙", "丙"] && model.liveRefreshFailed, "Failed refresh replaced usable list")
                try check(model.liveLastUpdated == goodDate && !model.isRefreshingLive, "Failure changed success time or left loading active")
            }
            try await control(base, "/set/updated")
            model.liveURL = base + "/slow.txt"
            let old = Task { await model.loadLive() }
            try await Task.sleep(nanoseconds: 80_000_000)
            model.liveURL = base + "/live.txt"
            await model.loadLive()
            await old.value
            try check(model.liveChannels.map(\.name) == ["乙", "丙"], "Older request overwrote newer result")
            model.liveURL = base + "/slow.txt"
            let changed = Task { await model.loadLive() }
            try await Task.sleep(nanoseconds: 80_000_000)
            model.liveURL = base + "/live.txt"
            await changed.value
            try check(model.liveChannels.map(\.name) == ["乙", "丙"] && model.liveRefreshMessage.contains("地址已更改"), "Edited URL accepted obsolete response")
            try await control(base, "/set/empty")
            await model.loadLive()
            try check(model.liveChannels.isEmpty && model.liveRefreshMessage.contains("移除 2"), "Authoritative empty list kept deleted channels")
            let m3u = try LiveSourceClient.parse("\u{FEFF}#EXTM3U\n#EXTINF:-1 group-title=\"央视\",CCTV1,HD\nhttps://example.com/cctv1.m3u8?x=a,b\n")
            try check(m3u.first?.group == "央视" && m3u.first?.name == "CCTV1,HD" && m3u.count == 1, "M3U import failed")
            let cdn = URL(string: "https://cdn.jsdelivr.net/gh/oops1996/-tvbox-live@main/live.txt")!
            try check(LiveSourceClient.originURL(cdn).absoluteString == "https://raw.githubusercontent.com/oops1996/-tvbox-live/main/live.txt", "Mutable CDN not routed to original")
            for value in ["https://cdn.jsdelivr.net/gh/o/r@v1/live.txt", "https://cdn.jsdelivr.net/gh/o/r@main/live.txt?signature=test"] {
                let url = URL(string: value)!
                try check(LiveSourceClient.originURL(url) == url, "Pinned/signed URL altered")
            }
            try await control(base, "/assert-headers")
            let merged = try LiveSourceClient.parse("央视,#genre#\nCCTV10,https://example.com/1.m3u8\nCCTV10,https://example.com/2.m3u8\nCCTV10,https://example.com/2.m3u8\nCCTV10,https://example.com/3.m3u8\nCCTV10 HD,https://example.com/hd.m3u8\nCCTV10 4K,https://example.com/4k.m3u8\n")
            try check(merged.count == 3 && merged[0].lines.count == 3, "Duplicate channels/lines not merged or quality variants removed")
            let withHeaders = try LiveSourceClient.parse("#EXTM3U\n#EXTINF:-1,测试\n#EXTVLCOPT:http-user-agent=fixture-agent\n#EXTVLCOPT:http-referrer=https://example.com/\nhttps://example.com/a.m3u8\n#EXTINF:-1,测试\nhttps://example.com/b.m3u8|User-Agent=second-agent&Referer=https%3A%2F%2Fexample.com%2F\n")
            try check(withHeaders.count == 1 && withHeaders[0].lines[0].headers["User-Agent"] == "fixture-agent" && withHeaders[0].lines[1].headers["Referer"] == "https://example.com/", "Per-line request headers lost")
            model.liveChannels = merged
            model.favorites = [merged[0].lines[1].url]
            try check(model.isFavorite(merged[0]), "Legacy alternate-line favorite lost")
            model.play(channel: merged[0])
            let historyCount = model.history.count
            for expected in [1, 2] {
                model.playback.onFailure?(model.playback.currentURL!, "fixture failed")
                try check(model.selectedLineIndex == expected, "Failed line did not switch")
            }
            model.playback.onFailure?(model.playback.currentURL!, "fixture failed")
            try check(model.selectedLineIndex == 2 && model.livePlaybackMessage.contains("全部 3"), "Failed lines looped endlessly")
            try check(model.history.count == historyCount, "Automatic switching duplicated history")
            model.switchLiveLine(to: 1)
            model.playback.onVideoStarted?(model.playback.currentURL!)
            model.play(channel: merged[0])
            try check(model.selectedLineIndex == 1, "Working line not preferred for next playback")
            let obsolete = model.playback.currentURL!
            model.play(channel: merged[1])
            model.playback.onFailure?(obsolete, "obsolete failure")
            try check(model.selectedChannel?.name == "CCTV10 HD" && model.selectedLineIndex == 0, "Stale failure changed new channel")
            model.play(channel: withHeaders[0])
            try check(model.playback.currentHeaders["User-Agent"] == "fixture-agent", "Live request headers not passed to player")
            model.play(history: MediaHistory(id: UUID(), name: "旧线路", url: merged[0].lines[1].url, date: Date()))
            try check(model.selectedChannel?.id == merged[0].id, "Alternate-line history was treated as VOD")
            print("PASS: live refresh, cache bypass, deletion, request races, M3U headers, channel/line merging, bounded failover, working-line reuse, stale callbacks, favorites/history preservation")
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
