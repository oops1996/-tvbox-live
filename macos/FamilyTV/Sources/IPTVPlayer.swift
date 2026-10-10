import AppKit
import Combine
import SwiftUI
import VLCKit

/// Owns one VLC player and drawable across navigation and window changes. Credentials stay in memory.
@MainActor
final class IPTVPlayer: ObservableObject {
    @Published private(set) var hasMedia = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var isBuffering = false
    @Published private(set) var canSeek = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var status = "选择内容开始播放"
    @Published private(set) var failed = false
    @Published var volume: Double = 100 {
        didSet { player?.audio?.volume = Int32(max(0, min(100, volume))) }
    }
    @Published private(set) var isMuted = false
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var isLive = false
    @Published private(set) var mediaTitle = "家庭电视"
    @Published var isDetached = false
    @Published var isFullscreen = false
    @Published var isFloating = false
    @Published var fillVideo = false { didSet { videoView.fillScreen = fillVideo } }
    @Published private(set) var resolution = ""
    static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    var canChangeRate: Bool { hasMedia && !isLive }
    var elapsed: Double { max(0, position * duration) }
    var playerIdentity: ObjectIdentifier? { player.map(ObjectIdentifier.init) }
    var enginePlaybackRate: Float { player?.rate ?? 1 }
    lazy var presentation = PlaybackPresentation(playback: self)

    let videoView = PlaybackVideoView(frame: .zero)
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
        videoView.onDoubleClick = { [weak self] in self?.toggleFullscreen() }
        timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshState() }
    }

    func play(name: String, url: URL, headers: [String: String], isLive: Bool,
              softwareDecoding: Bool, cacheMilliseconds: Int) {
        request = Request(name: name, url: url, headers: headers, isLive: isLive,
                          softwareDecoding: softwareDecoding, cacheMilliseconds: cacheMilliseconds)
        self.isLive = isLive
        mediaTitle = name
        resolution = ""
        if isLive { playbackRate = 1 }
        presentation.updateTitle()
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
        next.audio?.isMuted = isMuted

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
            "rate": request.isLive ? 1 : playbackRate,
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
        next.rate = Float(request.isLive ? 1 : playbackRate)
        player = next
        startedAt = Date()
        receivedVideo = false
        failed = false
        hasMedia = true
        isBuffering = true
        isPlaying = false
        isPaused = false
        canSeek = false
        position = 0
        duration = 0
        status = "正在连接：\(request.name)"
        next.play()
    }

    func togglePause() {
        guard let player else { return }
        // VLCKit can retain a Buffering state after a seek or pause. Keep the user's
        // pause intent separately so Resume never pauses again or restarts the URL.
        if isPaused { isPaused = false; player.play() }
        else if player.state == .ended || player.state == .stopped || player.state == .error { retry() }
        else { isPaused = true; player.pause() }
        refreshState()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        isPaused = false
        isBuffering = false
        failed = false
        canSeek = false
        position = 0
        status = "已停止"
    }

    func retry() { startRequest() }

    func seek(to value: Double) {
        guard canSeek else { return }
        position = max(0, min(1, value))
        player?.position = Float(position)
    }

    func skip(seconds: Double) {
        guard canSeek, duration > 0 else { return }
        seek(to: position + seconds / duration)
    }

    func setRate(_ value: Double) {
        guard canChangeRate, Self.rates.contains(value) else { return }
        playbackRate = value
        player?.rate = Float(value)
    }

    func stepRate(_ direction: Int) {
        let index = Self.rates.firstIndex(of: playbackRate) ?? 2
        setRate(Self.rates[max(0, min(Self.rates.count - 1, index + direction))])
    }

    func toggleMute() {
        isMuted.toggle()
        player?.audio?.isMuted = isMuted
    }

    func detach() { presentation.showWindow() }
    func embed() { presentation.returnToEmbedded() }
    func toggleFullscreen() { presentation.toggleFullscreen() }
    func toggleFloating() { presentation.toggleFloating() }

    static func timeLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func refreshState() {
        guard let player, let request, hasMedia else { return }
        isPlaying = player.isPlaying && !isPaused
        duration = Double(player.media?.length.intValue ?? 0) / 1000
        canSeek = !request.isLive && player.isSeekable && duration > 0
        position = max(0, min(1, Double(player.position)))
        if let track = player.media?.tracksInformation.first(where: {
            ($0 as? [String: Any])?[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeVideo
        }) as? [String: Any],
           let width = track[VLCMediaTracksInformationVideoWidth] as? NSNumber,
           let height = track[VLCMediaTracksInformationVideoHeight] as? NSNumber,
           width.intValue > 0, height.intValue > 0 {
            resolution = "\(width.intValue) × \(height.intValue)"
        }
        receivedVideo = receivedVideo || (player.media?.statistics.displayedPictures ?? 0) > 0
        if isPaused {
            if player.isPlaying { player.pause() }
            isBuffering = false
            status = "已暂停：\(request.name)"
            return
        }
        switch player.state {
        case .opening, .buffering:
            // VLCKit caches every buffering event, including 100%, after Playing.
            // Confirm rendered frames instead of leaving a spinner over running video.
            isBuffering = !(isPlaying && receivedVideo)
            status = isBuffering ? "正在缓冲：\(request.name)" : "正在播放：\(request.name)"
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
