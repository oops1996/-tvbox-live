import AppKit
import VLCKit

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

    @MainActor static func waitForVideo(_ playback: IPTVPlayer, _ label: String) async throws {
        for _ in 0..<120 {
            if playback.isPlaying && !playback.isBuffering && !playback.failed { return }
            if playback.failed { throw Failure.check(label) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        print("Playback diagnostic: decoded=\(playback.decodedVideoFrames), displayed=\(playback.displayedVideoFrames), status=\(playback.status)")
        throw Failure.check(label)
    }

}
