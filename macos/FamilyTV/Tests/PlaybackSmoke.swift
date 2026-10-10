import AppKit
import VLCKit

final class PlaybackTestDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func removeObject(forKey key: String) { values[key] = nil }
}

@main
struct PlaybackSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                print("PASS: embedded VLC video, authenticated WebDAV, HLS, switching, controls and source catalogue")
                exit(0)
            } catch {
                print("FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
        app.run()
    }

    enum Failure: LocalizedError {
        case check(String)
        var errorDescription: String? { if case .check(let text) = self { return text }; return nil }
    }
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        if !condition() { throw Failure.check(label) }
    }
    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw Failure.check("Usage: PlaybackSmoke fixture-directory base-url") }
        let base = args[2]
        let playback = IPTVPlayer()
        playback.volume = 0
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 480, height: 270),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let embeddedHost = PlaybackVideoHost(playback: playback, role: .embedded)
        window.contentView = embeddedHost
        window.orderFront(nil)

        let env = ProcessInfo.processInfo.environment
        let user = env["FAMILYTV_TEST_USER"] ?? ""
        let password = env["FAMILYTV_TEST_PASSWORD"] ?? ""
        try check(!user.isEmpty && !password.isEmpty, "Test credentials not provided")
        let auth = ["Authorization": "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()]
        // Includes reserved characters to validate URL credential escaping and Basic authentication.
        playback.play(name: "WebDAV fixture", url: URL(string: base + "/dav/sample.mp4")!, headers: auth,
                      isLive: false, softwareDecoding: true, cacheMilliseconds: 500)
        try await waitForVideo(playback, "Authenticated MP4 did not render")
        try check(playback.canSeek, "VOD seek unavailable")
        playback.seek(to: 0.3)
        playback.togglePause()
        try await Task.sleep(nanoseconds: 600_000_000)
        try check(!playback.isPlaying, "Pause failed")
        let identity = playback.playerIdentity
        let pausedPosition = playback.position
        playback.setRate(1.5)
        playback.detach()
        try await Task.sleep(nanoseconds: 800_000_000)
        try check(playback.isDetached && playback.videoView.window === playback.presentation.window,
                  "Detached window did not acquire the same video view")
        try check(playback.playerIdentity == identity && abs(playback.position - pausedPosition) < 0.01,
                  "Detaching restarted media or changed paused position")
        try check(playback.playbackRate == 1.5, "Playback rate not retained")
        playback.embed()
        try await Task.sleep(nanoseconds: 300_000_000)
        embeddedHost.attachIfActive()
        try check(!playback.isDetached && playback.playerIdentity == identity, "Embedding recreated the decoder")
        playback.seek(to: -2)
        try check(playback.position == 0, "Negative seek not clamped")
        playback.seek(to: 0.1)
        playback.skip(seconds: 2)
        try check(playback.position > 0.1, "Relative forward seek failed")
        playback.toggleMute()
        try check(playback.isMuted, "Mute failed")
        playback.toggleMute()
        playback.togglePause()
        try await waitForVideo(playback, "Playback did not resume after embedding")
        let before = playback.elapsed
        try await Task.sleep(nanoseconds: 2_000_000_000)
        print("RATE CHECK: before=\(before) after=\(playback.elapsed) engine=\(playback.enginePlaybackRate)")
        try check(playback.elapsed > before + 2.3, "1.5x rate did not advance the playback clock")
        playback.play(name: "HLS fixture", url: URL(string: base + "/dav/sample.m3u8")!, headers: auth,
                      isLive: true, softwareDecoding: true, cacheMilliseconds: 500)
        try await waitForVideo(playback, "Authenticated HLS did not render")
        try check(!playback.canSeek, "Live must not seek")
        playback.setRate(2)
        try check(playback.playbackRate == 1 && !playback.canChangeRate, "Live rate must remain 1x")
        playback.retry()
        try await waitForVideo(playback, "Retry did not render")
        playback.stop()
        try check(!playback.isPlaying, "Stop failed")

        let defaults = PlaybackTestDefaults()
        defaults.set(base + "/live/list.m3u", forKey: "liveURL")
        let model = AppModel(defaults: defaults)
        await model.loadLive()
        try check(model.liveChannels.count == 1 && model.liveChannels[0].lines.count == 2, "Duplicate live channels not grouped")
        let recoveryHost = PlaybackVideoHost(playback: model.playback, role: .embedded)
        window.contentView = recoveryHost
        model.playback.volume = 0
        model.play(channel: model.liveChannels[0])
        try await waitForVideo(model.playback, "Failed live line did not switch to playable HLS")
        try check(model.selectedLineIndex == 1 && model.history.count == 1, "Wrong recovery line or duplicate history")
        model.playback.stop()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try check(!model.playback.isPlaying && model.selectedLineIndex == 1, "Stop triggered automatic live playback")
        model.playback.togglePause()
        try await waitForVideo(model.playback, "Playback button did not restart stopped live media")
        model.playback.stop()
        print("PASS: real VLC failure switches to decoded HLS with User-Agent/Referer on child requests, duplicate channel merged, stop respected")

        model.selectedChannel = nil
        model.liveDirectConnection = true
        model.play(channel: model.liveChannels[0], line: 1)
        model.playback.stop()
        try await Task.sleep(nanoseconds: 600_000_000)
        try check(model.playback.playerIdentity == nil, "Stopped direct startup resumed after endpoint became ready")
        model.play(channel: model.liveChannels[0], line: 1)
        try await waitForVideo(model.playback, "Direct HLS relay did not decode with child request headers")
        try check(model.history.allSatisfy { !$0.url.contains("/direct/") }, "Transport URL leaked into history")
        model.playback.stop()
        print("PASS: direct HLS relay decoded with child headers; startup cancellation and original history URLs preserved")

        if let snapshot = env["FAMILYTV_TEST_LIVE_SNAPSHOT"] {
            model.liveChannels = try LiveSourceClient.parse(String(contentsOfFile: snapshot, encoding: .utf8))
            let direct = env["FAMILYTV_TEST_LIVE_DIRECT"] == "1"
            model.playback.stop(); model.selectedChannel = nil
            model.liveDirectConnection = direct
            for name in direct ? ["江西卫视", "CCTV7", "湖南卫视"] : ["CCTV7", "湖南卫视"] {
                guard let channel = model.liveChannels.first(where: { $0.name == name }) else { throw Failure.check("Missing live test channel") }
                model.play(channel: channel)
                try await waitForVideo(model.playback, "Actual \(name) did not render", timeout: 55)
                let frames = model.playback.displayedVideoFrames
                try await Task.sleep(nanoseconds: 3_000_000_000)
                try check(model.playback.displayedVideoFrames > frames + 5, "Real live stopped rendering")
                print("REAL LIVE: \(name) direct=\(direct) line=\(model.selectedLineIndex + 1)/\(channel.lines.count) displayed=\(model.playback.displayedVideoFrames) resolution=\(model.playback.resolution)")
                model.playback.stop()
            }
        }

        let imported = try await FilmSourceClient.importSources(from: base + "/config.json")
        try check(imported.count == 2 && imported.filter(\.canBrowse).count == 1, "TVBox compatibility detection failed")
        let native = imported.first { $0.canBrowse }!
        let home = try await FilmSourceClient.request(native)
        try check(Set(home.categories.map(\.group)) == Set(["电影", "电视剧", "综艺"]), "Categories failed")
        let category = try await FilmSourceClient.request(native, category: "2", page: 2)
        try check(category.items.first?.name == "第 2 页电视剧", "Category or page parameters failed")
        let search = try await FilmSourceClient.request(native, search: "测试 搜索")
        try check(search.items.first?.name == "测试 搜索", "Search encoding failed")
        let detail = try await FilmSourceClient.request(native, id: "1")
        try check(detail.items.first?.lines.first?.episodes.count == 2, "Episode parsing failed")
        let xml = try await FilmSourceClient.importSources(from: base + "/api.xml")
        let xmlPage = try await FilmSourceClient.request(xml[0])
        try check(xmlPage.categories.count == 3 && xmlPage.items.first?.lines.first?.episodes.count == 2, "XML catalogue failed")
        let embedded = Data([0xff,0xd8,0xff,0xd9]) + Data("marker**".utf8) + Data(Data("{ /* comment */ sites: [], }".utf8).base64EncodedString().utf8)
        let embeddedJSON = try FilmSourceClient.json(embedded)
        try check(embeddedJSON["sites"] != nil, "Image/JSON5 envelope failed")
        let unicodeURL = try FilmSourceClient.url("http://www.饭太硬.net/tv")
        try check(unicodeURL.host != nil, "Unicode URL failed")
        window.orderOut(nil)
    }

    @MainActor static func waitForVideo(_ playback: IPTVPlayer, _ label: String, timeout: Double = 12) async throws {
        for _ in 0..<Int(timeout * 10) {
            if playback.isPlaying && !playback.isBuffering && !playback.failed { return }
            if playback.failed { throw Failure.check(label) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        print("Playback diagnostic: decoded=\(playback.decodedVideoFrames), displayed=\(playback.displayedVideoFrames), status=\(playback.status), ticks=\(playback.stateRefreshCount), engine=\(playback.engineState), hasMedia=\(playback.hasMedia), failed=\(playback.failed), paused=\(playback.isPaused)")
        throw Failure.check(label)
    }

}
