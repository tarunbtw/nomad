//
//  FloatingVideoManager.swift
//  nomad
//
//  Created by tarun on 14/10/26.
//

import AppKit
import WebKit
import Combine
import SwiftUI

/// Manages native Picture-in-Picture / Floating Video for Nomad.
/// Bypasses WebKit's programmatic click restrictions by lifting the active WKWebView
/// into a borderless, always-on-top NSPanel while isolating the video element via full-viewport CSS.
@MainActor
final class FloatingVideoManager: ObservableObject {
    static let shared = FloatingVideoManager()

    private var panel: FloatPanel?
    private var floatState = FloatState()
    private weak var controlsHost: NSView?
    private weak var activeTab: Tab?
    private weak var hostedWebView: WKWebView?
    private var ticker: Timer?

    var isFloating: Bool { panel != nil }
    var floatingTabId: UUID? { activeTab?.id }

    private init() {}

    /// Toggles floating video for the given tab.
    func toggle(tab: Tab) {
        if isFloating {
            land()
        } else {
            lift(tab: tab)
        }
    }

    /// Lifts the video from the specified tab into an always-on-top floating panel.
    func lift(tab: Tab) {
        guard !isFloating else { return }
        guard !tab.isBlank && !tab.isInternalPage else { return }

        let webView = tab.webView
        webView.evaluateJavaScript(IsolateScript.on) { [weak self, weak tab] result, error in
            guard let self = self, let tab = tab else { return }
            var aspectW: Double = 16
            var aspectH: Double = 9
            var isSuccess = false

            if let jsonStr = result as? String,
               let data = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               dict["status"] as? String == "floating" {
                isSuccess = true
                aspectW = (dict["width"] as? Double) ?? 16
                aspectH = (dict["height"] as? Double) ?? 9
            } else if (result as? String) == "floating" {
                isSuccess = true
            }

            if isSuccess {
                self.present(tab: tab, aspectWidth: aspectW, aspectHeight: aspectH)
            } else {
                print("⚠️ [FloatingVideoManager] No playing video found on this page.")
            }
        }
    }

    private func present(tab: Tab, aspectWidth: Double = 16, aspectHeight: Double = 9) {
        self.activeTab = tab
        self.hostedWebView = tab.webView
        tab.isFloatingVideo = true

        let ratio = (aspectWidth > 0 && aspectHeight > 0) ? CGFloat(aspectWidth / aspectHeight) : CGFloat(16.0 / 9.0)
        let defaultWidth: CGFloat = 440
        let defaultHeight: CGFloat = round(defaultWidth / ratio)
        let defaultSize = NSSize(width: defaultWidth, height: max(180, min(500, defaultHeight)))

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultOrigin = NSPoint(
            x: screen.maxX - defaultSize.width - 24,
            y: screen.minY + 24
        )

        var spot = NSRect(origin: defaultOrigin, size: defaultSize)
        if let saved = UserDefaults.standard.string(forKey: "nomad.float.frame") {
            let parsed = NSRectFromString(saved)
            if parsed.width >= 200 && parsed.height >= 120 {
                spot = parsed
            }
        }

        let panel = FloatPanel(
            contentRect: spot,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.aspectRatio = (aspectWidth > 0 && aspectHeight > 0) ? NSSize(width: aspectWidth, height: aspectHeight) : defaultSize
        panel.minSize = NSSize(width: 260, height: 146)

        let ground = NSView(frame: NSRect(origin: .zero, size: spot.size))
        ground.wantsLayer = true
        ground.layer?.backgroundColor = NSColor.black.cgColor
        ground.layer?.cornerRadius = 14
        ground.layer?.masksToBounds = true

        let webView = tab.webView
        webView.allowsMagnification = false
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
            webView.topAnchor.constraint(equalTo: ground.topAnchor),
            webView.bottomAnchor.constraint(equalTo: ground.bottomAnchor)
        ])

        let controlsView = FloatControlsView(
            state: floatState,
            onClose: { [weak self] in self?.land() },
            onReturn: { [weak self] in self?.returnToTab() },
            onPlayPause: { [weak self] in self?.togglePlayback() },
            onSkip: { [weak self] seconds in self?.skip(seconds: seconds) }
        )
        let controlsHost = NSHostingView(rootView: controlsView)
        controlsHost.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(controlsHost)
        NSLayoutConstraint.activate([
            controlsHost.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            controlsHost.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
            controlsHost.topAnchor.constraint(equalTo: ground.topAnchor),
            controlsHost.bottomAnchor.constraint(equalTo: ground.bottomAnchor)
        ])
        self.controlsHost = controlsHost

        panel.contentView = ground
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        self.panel = panel

        startProgressTicker()
    }

    /// Lands the floating video and restores the web view to its tab.
    func land() {
        guard let panel = panel else { return }

        // Save window position
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "nomad.float.frame")

        ticker?.invalidate()
        ticker = nil

        if let tab = activeTab {
            tab.isFloatingVideo = false
            tab.webView.allowsMagnification = true
            tab.webView.removeFromSuperview()
            tab.webView.evaluateJavaScript(IsolateScript.off, completionHandler: nil)
            tab.objectWillChange.send()
        } else if let webView = hostedWebView {
            webView.allowsMagnification = true
            webView.removeFromSuperview()
            webView.evaluateJavaScript(IsolateScript.off, completionHandler: nil)
        }

        controlsHost = nil
        hostedWebView = nil
        activeTab = nil

        panel.orderOut(nil)
        self.panel = nil
    }

    /// Lands if the floating tab matches the given ID.
    func landIfTab(id: UUID) {
        if activeTab?.id == id {
            land()
        }
    }

    /// Brings Nomad back to the front, selects the tab, and lands the floating video.
    func returnToTab() {
        land()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.contentView != nil }?.makeKeyAndOrderFront(nil)
    }

    private func togglePlayback() {
        guard let webView = hostedWebView else { return }
        webView.evaluateJavaScript(IsolateScript.toggle) { [weak self] result, _ in
            if let isPlaying = result as? Bool {
                self?.floatState.isPlaying = isPlaying
            }
        }
    }

    private func skip(seconds: Double) {
        guard let webView = hostedWebView else { return }
        webView.evaluateJavaScript(IsolateScript.skip(seconds), completionHandler: nil)
    }

    private func startProgressTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let webView = self.hostedWebView, let ground = self.panel?.contentView else { return }
                
                // Guarantee the webView remains attached to the ground container
                if webView.superview !== ground {
                    webView.removeFromSuperview()
                    webView.translatesAutoresizingMaskIntoConstraints = false
                    if let ctrl = self.controlsHost {
                        ground.addSubview(webView, positioned: .below, relativeTo: ctrl)
                    } else {
                        ground.addSubview(webView)
                    }
                    NSLayoutConstraint.activate([
                        webView.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
                        webView.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
                        webView.topAnchor.constraint(equalTo: ground.topAnchor),
                        webView.bottomAnchor.constraint(equalTo: ground.bottomAnchor)
                    ])
                }

                if let result = try? await webView.evaluateJavaScript(IsolateScript.whereProgress) as? [Any],
                   result.count >= 2 {
                    let progress = result[0] as? Double ?? 0.0
                    let isPlaying = result[1] as? Bool ?? true
                    self.floatState.progress = progress
                    self.floatState.isPlaying = isPlaying
                }
            }
        }
    }
}

// MARK: - FloatPanel
private final class FloatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - FloatState & FloatControlsView (Declarative SwiftUI Overlay)
private final class FloatState: ObservableObject {
    @Published var isPlaying: Bool = true
    @Published var progress: Double = 0.0
}

private struct FloatControlsView: View {
    @ObservedObject var state: FloatState
    var onClose: () -> Void
    var onReturn: () -> Void
    var onPlayPause: () -> Void
    var onSkip: (Double) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        ZStack {
            if isHovered {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.45),
                        Color.clear,
                        Color.clear,
                        Color.black.opacity(0.55)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                VStack {
                    HStack {
                        button(icon: "xmark", size: 11, circleSize: 30, action: onClose)
                        Spacer()
                        button(icon: "arrow.up.forward", size: 12, circleSize: 30, action: onReturn)
                    }
                    .padding(14)

                    Spacer()

                    HStack(spacing: 16) {
                        button(icon: "gobackward.15", size: 15, circleSize: 38, action: { onSkip(-15) })
                        button(icon: state.isPlaying ? "pause.fill" : "play.fill", size: 18, circleSize: 50, action: onPlayPause)
                        button(icon: "goforward.15", size: 15, circleSize: 38, action: { onSkip(15) })
                    }

                    Spacer()

                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color(red: 0.95, green: 0.26, blue: 0.21, opacity: 0.9))
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, state.progress))), height: 3)
                    }
                    .frame(height: 3)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.16), value: isHovered)
    }

    private func button(icon: String, size: CGFloat, circleSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: circleSize, height: circleSize)
                .background(Color.black.opacity(0.65), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Isolate JavaScript (Proven macOS WebKit Isolation Architecture)
private enum IsolateScript {
    static let on = """
    (function () {
      var best = document.querySelector('video.html5-main-video') ||
                 document.querySelector('video.video-stream');
      if (!best || best.ended) {
        var videos = document.querySelectorAll('video');
        var area = 0;
        for (var i = 0; i < videos.length; i++) {
          var v = videos[i];
          if (v.paused || v.ended || v.readyState < 1) continue;
          var box = v.getBoundingClientRect();
          if (box.width * box.height >= area) { area = box.width * box.height; best = v; }
        }
        if (!best) {
          area = 0;
          for (var i = 0; i < videos.length; i++) {
            var v = videos[i];
            if (v.ended) continue;
            var box = v.getBoundingClientRect();
            if (box.width * box.height >= area) { area = box.width * box.height; best = v; }
          }
        }
      }
      if (!best) return 'none';

      window.__nomadFloatScroll = { x: window.scrollX, y: window.scrollY };
      window.scrollTo(0, 0);

      window.__nomadFloatLanding = null;
      best.setAttribute('data-nomad-float', '');
      var sheet = document.getElementById('nomad-float');
      if (!sheet) {
        sheet = document.createElement('style');
        sheet.id = 'nomad-float';
        (document.head || document.documentElement).appendChild(sheet);
      }
      sheet.textContent = [
        'html.nomad-floating, html.nomad-floating body {',
        '  background: #000 !important;',
        '  overflow: hidden !important;',
        '  margin: 0 !important;',
        '  padding: 0 !important;',
        '  width: 100vw !important;',
        '  height: 100vh !important;',
        '}',
        'html.nomad-floating * {',
        '  visibility: hidden !important;',
        '}',
        'html.nomad-floating :has([data-nomad-float]) {',
        '  overflow: visible !important;',
        '  transform: none !important;',
        '  translate: none !important;',
        '  rotate: none !important;',
        '  scale: none !important;',
        '  filter: none !important;',
        '  backdrop-filter: none !important;',
        '  -webkit-backdrop-filter: none !important;',
        '  perspective: none !important;',
        '  contain: none !important;',
        '  container-type: normal !important;',
        '  will-change: auto !important;',
        '  clip-path: none !important;',
        '  mask: none !important;',
        '  -webkit-mask: none !important;',
        '  background: transparent !important;',
        '  border: none !important;',
        '}',
        'html.nomad-floating [data-nomad-float] {',
        '  visibility: visible !important;',
        '  position: fixed !important;',
        '  left: 0 !important;',
        '  top: 0 !important;',
        '  right: 0 !important;',
        '  bottom: 0 !important;',
        '  width: 100vw !important;',
        '  height: 100vh !important;',
        '  max-width: 100vw !important;',
        '  max-height: 100vh !important;',
        '  min-width: 100vw !important;',
        '  min-height: 100vh !important;',
        '  margin: 0 !important;',
        '  padding: 0 !important;',
        '  border: none !important;',
        '  transform: none !important;',
        '  translate: none !important;',
        '  rotate: none !important;',
        '  scale: none !important;',
        '  opacity: 1 !important;',
        '  object-fit: contain !important;',
        '  z-index: 2147483647 !important;',
        '}',
        'html.nomad-floating .player-timedtext,',
        'html.nomad-floating .ytp-caption-window-bottom,',
        'html.nomad-floating .caption-window {',
        '  visibility: visible !important;',
        '  z-index: 2147483647 !important;',
        '}',
        'html.nomad-floating [data-nomad-float]::-webkit-media-controls {',
        '  display: none !important;',
        '}'
      ].join('\\n');
      document.documentElement.classList.add('nomad-floating');

      clearInterval(window.__nomadFloatWatch);
      window.__nomadFloatWatch = setInterval(function () {
        if (document.querySelector('[data-nomad-float]')) return;
        var again = document.querySelector('video.html5-main-video') ||
                    document.querySelector('video.video-stream');
        if (!again) {
          var all = document.querySelectorAll('video');
          var most = 0;
          for (var j = 0; j < all.length; j++) {
            var one = all[j];
            if (one.ended) continue;
            var shape = one.getBoundingClientRect();
            if (shape.width * shape.height >= most) {
              most = shape.width * shape.height;
              again = one;
            }
          }
        }
        if (again) again.setAttribute('data-nomad-float', '');
      }, 250);

      return JSON.stringify({
        status: 'floating',
        width: best.videoWidth || 16,
        height: best.videoHeight || 9
      });
    })();
    """

    static let off = """
    (function () {
      var root = document.documentElement;
      var landing = window.__nomadFloatLanding = {};
      function put() {
        if (window.__nomadFloatLanding !== landing) return;
        window.__nomadFloatLanding = null;
        clearInterval(window.__nomadFloatWatch);
        window.__nomadFloatWatch = null;
        root.classList.remove('nomad-floating');
        var sheet = document.getElementById('nomad-float');
        if (sheet) sheet.textContent = '';
        var video = document.querySelector('[data-nomad-float]');
        if (video) video.removeAttribute('data-nomad-float');
        if (window.__nomadFloatScroll) {
          window.scrollTo(window.__nomadFloatScroll.x, window.__nomadFloatScroll.y);
          window.__nomadFloatScroll = null;
        }
      }
      put();
      return 'landed';
    })();
    """

    static func skip(_ seconds: Double) -> String {
        """
        (function () {
          var video = document.querySelector('[data-nomad-float]') || document.querySelector('video');
          if (!video) return false;
          video.currentTime = Math.max(0, video.currentTime + (\(seconds)));
          return true;
        })();
        """
    }

    static let toggle = """
    (function () {
      var video = document.querySelector('[data-nomad-float]') || document.querySelector('video');
      if (!video) return true;
      if (video.paused) { video.play(); } else { video.pause(); }
      return !video.paused;
    })();
    """

    static let whereProgress = """
    (function () {
      var video = document.querySelector('[data-nomad-float]') || document.querySelector('video');
      if (!video || !video.duration || !isFinite(video.duration)) return [0, true];
      return [video.currentTime / video.duration, !video.paused];
    })();
    """
}
