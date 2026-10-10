import AppKit
import SwiftUI
import VLCKit

enum PlaybackSurfaceRole { case embedded, window }

/// Only one drawable is moved between hosts; switching presentation never recreates VLC.
@MainActor
final class PlaybackVideoView: VLCVideoView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
        else { super.mouseDown(with: event) }
    }
}

@MainActor
final class PlaybackVideoHost: NSView {
    weak var playback: IPTVPlayer?
    let role: PlaybackSurfaceRole
    init(playback: IPTVPlayer, role: PlaybackSurfaceRole) {
        self.playback = playback
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attachIfActive() }
    func attachIfActive() {
        guard let playback, window != nil,
              playback.isDetached == (role == .window) else { return }
        if role == .embedded { playback.presentation.embeddedWindow = window }
        if playback.videoView.superview !== self {
            playback.videoView.removeFromSuperview()
            playback.videoView.autoresizingMask = [.width, .height]
            playback.videoView.frame = bounds
            addSubview(playback.videoView)
        }
        playback.presentation.installKeyboardControls()
    }
    override func layout() {
        super.layout()
        if let video = playback?.videoView, video.superview === self { video.frame = bounds }
    }
}

struct VLCVideoSurface: NSViewRepresentable {
    @ObservedObject var playback: IPTVPlayer
    var role: PlaybackSurfaceRole = .embedded
    func makeNSView(context: Context) -> PlaybackVideoHost { PlaybackVideoHost(playback: playback, role: role) }
    func updateNSView(_ view: PlaybackVideoHost, context: Context) { view.attachIfActive() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlaybackVideoHost, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        // The drawable's previous dimensions must not become a minimum when a pane narrows.
        return CGSize(width: max(0, width), height: max(0, height))
    }
}

@MainActor
final class PlaybackPresentation: NSObject, NSWindowDelegate {
    private unowned let playback: IPTVPlayer
    private(set) var window: NSWindow?
    weak var embeddedWindow: NSWindow?
    private var returnAfterFullscreen = false
    private var pendingEmbed = false
    private var keyboardMonitor: Any?

    init(playback: IPTVPlayer) { self.playback = playback }

    func updateTitle() { window?.title = playback.mediaTitle }

    func showWindow() {
        returnAfterFullscreen = false
        guard window == nil else { window?.makeKeyAndOrderFront(nil); return }
        playback.isDetached = true
        let next = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
        next.title = playback.mediaTitle
        next.minSize = NSSize(width: 680, height: 470)
        next.backgroundColor = .black
        next.collectionBehavior = [.fullScreenPrimary]
        next.isReleasedWhenClosed = false
        next.delegate = self
        next.contentView = NSHostingView(rootView: PlayerContent(playback: playback, role: .window)
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black).preferredColorScheme(.dark))
        window = next
        next.center()
        next.makeKeyAndOrderFront(nil)
    }

    func toggleFullscreen() {
        if window == nil {
            showWindow()
            returnAfterFullscreen = true
        }
        guard let window else { return }
        // A normal window level allows the system fullscreen animation to complete.
        window.level = .normal
        window.toggleFullScreen(nil)
    }

    func toggleFloating() {
        playback.isFloating.toggle()
        if !playback.isFullscreen { window?.level = playback.isFloating ? .floating : .normal }
    }

    func returnToEmbedded() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) || playback.isFullscreen {
            pendingEmbed = true
            window.toggleFullScreen(nil)
        } else { finishEmbedding() }
    }

    private func finishEmbedding() {
        let previous = window
        window = nil
        previous?.delegate = nil
        playback.isDetached = false
        playback.isFullscreen = false
        playback.isFloating = false
        pendingEmbed = false
        returnAfterFullscreen = false
        previous?.orderOut(nil)
        // Let the embedded SwiftUI host attach on its next update, preserving the media clock.
        previous?.contentView = nil
        previous?.close()
        embeddedWindow?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { returnToEmbedded(); return false }
    func windowDidEnterFullScreen(_ notification: Notification) { playback.isFullscreen = true }
    func windowWillExitFullScreen(_ notification: Notification) { playback.isFullscreen = false }
    func windowDidExitFullScreen(_ notification: Notification) {
        if pendingEmbed || returnAfterFullscreen { finishEmbedding() }
        else { window?.level = playback.isFloating ? .floating : .normal }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        playback.isFullscreen = false
        returnAfterFullscreen = false
        window.level = playback.isFloating ? .floating : .normal
    }

    func installKeyboardControls() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                let video = self.playback.videoView
                if event.clickCount == 2, event.window === video.window,
                   video.bounds.contains(video.convert(event.locationInWindow, from: nil)) {
                    self.toggleFullscreen()
                    return nil
                }
                return event
            }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard playback.hasMedia, event.window === playback.videoView.window,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(event.window?.firstResponder is NSTextView) else { return false }
        switch event.keyCode {
        case 49: playback.togglePause() // Space
        case 123: guard playback.canSeek else { return false }; playback.skip(seconds: -10)
        case 124: guard playback.canSeek else { return false }; playback.skip(seconds: 10)
        case 125: playback.volume = max(0, playback.volume - 5)
        case 126: playback.volume = min(100, playback.volume + 5)
        case 53:
            guard playback.isFullscreen else { return false }
            toggleFullscreen()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": toggleFullscreen()
            case "m": playback.toggleMute()
            case "[", "-": guard playback.canChangeRate else { return false }; playback.stepRate(-1)
            case "]", "=", "+": guard playback.canChangeRate else { return false }; playback.stepRate(1)
            case "0": playback.setRate(1)
            default: return false
            }
        }
        return true
    }
}
