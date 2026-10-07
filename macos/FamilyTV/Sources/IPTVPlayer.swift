import AppKit
import Combine
import SwiftUI
import VLCKit

/// Owns one embedded VLC drawable across navigation. No credentials are persisted here.
@MainActor
final class IPTVPlayer: ObservableObject {
    @Published private(set) var hasMedia = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var canSeek = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var status = "选择内容开始播放"
    @Published private(set) var failed = false
    @Published var volume: Double = 100 {
        didSet { player?.audio?.volume = Int32(volume) }
    }

    let videoView = VLCVideoView(frame: .zero)
    var decodedVideoFrames: Int { Int(player?.media?.statistics.decodedVideo ?? 0) }
    var displayedVideoFrames: Int { Int(player?.media?.statistics.displayedPictures ?? 0) }
    private var player: VLCMediaPlayer?
    private var timer: AnyCancellable?
    private var request: Request?
    private var startedAt = Date()
    private var receivedVideo = false

    private struct Request {
        let name: String
        let url: URL
        let headers: [String: String]
        let isLive: Bool
        let softwareDecoding: Bool
        let cacheMilliseconds: Int
    }

    init() {
        videoView.fillScreen = false
        timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshState() }
    }

    func play(name: String, url: URL, headers: [String: String], isLive: Bool,
              softwareDecoding: Bool, cacheMilliseconds: Int) {
        request = Request(name: name, url: url, headers: headers, isLive: isLive,
                          softwareDecoding: softwareDecoding, cacheMilliseconds: cacheMilliseconds)
        startRequest()
    }

    private func startRequest() {
        guard let request else { return }
        // Disconnect the old drawable before switching to avoid stale frames and extra windows.
        player?.drawable = nil
        player?.stop()
        let next = VLCMediaPlayer(options: ["--quiet", "--no-video-title-show",
                                            "--no-media-library", "--no-interact"])
        next.drawable = videoView
        next.audio?.volume = Int32(volume)

        var mediaURL = request.url
        // libVLC's HTTP access modules support URL credentials (including HLS child requests).
        // They stay in memory; history retains the original credential-free URL.
        if let authorization = request.headers.first(where: { $0.key.lowercased() == "authorization" })?.value,
           authorization.hasPrefix("Basic "),
           let data = Data(base64Encoded: String(authorization.dropFirst(6))),
           let credentials = String(data: data, encoding: .utf8),
           let colon = credentials.firstIndex(of: ":"),
           var components = URLComponents(url: mediaURL, resolvingAgainstBaseURL: false) {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            components.percentEncodedUser = String(credentials[..<colon]).addingPercentEncoding(withAllowedCharacters: allowed)
            components.percentEncodedPassword = String(credentials[credentials.index(after: colon)...]).addingPercentEncoding(withAllowedCharacters: allowed)
            mediaURL = components.url ?? mediaURL
        }
        let media = VLCMedia(url: mediaURL)
        media.addOptions([
            "network-caching": max(500, min(5000, request.cacheMilliseconds)),
            "file-caching": 1000,
            "avcodec-hw": request.softwareDecoding ? "none" : "any"
        ])
        for (key, value) in request.headers where !value.contains("\r") && !value.contains("\n") {
            switch key.lowercased() {
            case "user-agent": media.addOption("http-user-agent=\(value)")
            case "referer": media.addOption("http-referrer=\(value)")
            default: break
            }
        }
        next.media = media
        player = next
        startedAt = Date()
        receivedVideo = false
        failed = false
        hasMedia = true
        isBuffering = true
        isPlaying = false
        canSeek = false
        position = 0
        duration = 0
        status = "正在连接：\(request.name)"
        next.play()
    }

    func togglePause() {
        guard let player else { return }
        if player.isPlaying { player.pause() }
        else if player.state == .paused { player.play() }
        else { retry() }
        refreshState()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        isBuffering = false
        failed = false
        status = "已停止"
    }

    func retry() { startRequest() }

    func seek(to value: Double) {
        guard canSeek else { return }
        player?.position = Float(max(0, min(1, value)))
        position = value
    }

    private func refreshState() {
        guard let player, let request, hasMedia else { return }
        isPlaying = player.isPlaying
        duration = Double(player.media?.length.intValue ?? 0) / 1000
        canSeek = !request.isLive && player.isSeekable && duration > 0
        position = Double(player.position)
        receivedVideo = receivedVideo || (player.media?.statistics.displayedPictures ?? 0) > 0
        switch player.state {
        case .opening, .buffering:
            isBuffering = true
            status = "正在缓冲：\(request.name)"
        case .playing:
            isBuffering = !receivedVideo
            status = receivedVideo ? "正在播放：\(request.name)" : "正在等待视频画面：\(request.name)"
        case .paused:
            isBuffering = false
            status = "已暂停：\(request.name)"
        case .error:
            markFailed()
        case .ended:
            isBuffering = false
            status = request.isLive ? "直播连接已结束，可点击重试" : "播放已结束"
        case .stopped:
            isBuffering = false
        default: break
        }
        // A playback clock alone is not proof of decoded video. Make silent black screens actionable.
        if isBuffering && Date().timeIntervalSince(startedAt) > 30 && !receivedVideo {
            player.stop()
            markFailed()
        }
    }

    private func markFailed() {
        failed = true
        isBuffering = false
        status = "未能读取视频画面。可重试、切换频道，或在设置中调整软件解码和缓冲。"
    }
}

struct VLCVideoSurface: NSViewRepresentable {
    @ObservedObject var playback: IPTVPlayer
    func makeNSView(context: Context) -> VLCVideoView { playback.videoView }
    func updateNSView(_ nsView: VLCVideoView, context: Context) {}
}
