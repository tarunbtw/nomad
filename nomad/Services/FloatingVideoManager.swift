//
//  FloatingVideoManager.swift
//  nomad
//
//  Created by tarun on 14/10/26.
//

import AppKit
import WebKit
import Combine

/// Manages native Picture-in-Picture / Floating Video for Nomad.
/// Bypasses WebKit's programmatic click restrictions by lifting the active WKWebView
/// into a borderless, always-on-top NSPanel while isolating the video element via full-viewport CSS.
@MainActor
final class FloatingVideoManager: ObservableObject {
    static let shared = FloatingVideoManager()

    private var panel: FloatPanel?
    private var controls: FloatControls?
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
            if (result as? String) == "floating" {
                self.present(tab: tab)
            } else {
                print("⚠️ [FloatingVideoManager] No playing video found on this page.")
            }
        }
    }

    private func present(tab: Tab) {
        self.activeTab = tab
        self.hostedWebView = tab.webView
        tab.isFloatingVideo = true

        let defaultSize = NSSize(width: 440, height: 247)
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
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.aspectRatio = defaultSize
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

        let controls = FloatControls(frame: ground.bounds)
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.onClose = { [weak self] in
            self?.land()
        }
        controls.onReturn = { [weak self] in
            self?.returnToTab()
        }
        controls.onPlayPause = { [weak self] in
            self?.togglePlayback()
        }
        controls.onSkip = { [weak self] seconds in
            self?.skip(seconds: seconds)
        }
        ground.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
            controls.topAnchor.constraint(equalTo: ground.topAnchor),
            controls.bottomAnchor.constraint(equalTo: ground.bottomAnchor)
        ])
        self.controls = controls

        panel.contentView = ground
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

        controls = nil
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
                self?.controls?.isPlaying = isPlaying
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
                    if let ctrl = self.controls {
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
                    self.controls?.progress = progress
                    self.controls?.isPlaying = isPlaying
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

// MARK: - FloatControls
private final class FloatControls: NSView {
    var onClose: (() -> Void)?
    var onReturn: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onSkip: ((Double) -> Void)?

    var isPlaying: Bool = true {
        didSet {
            let symbol = isPlaying ? "pause.fill" : "play.fill"
            pauseBtn.image = glyph(symbol, 18)
        }
    }

    var progress: Double = 0.0 {
        didSet {
            let clamped = max(0, min(1, progress))
            progressBar.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(clamped), height: 3)
        }
    }

    private let closeBtn = NSButton()
    private let returnBtn = NSButton()
    private let rewindBtn = NSButton()
    private let pauseBtn = NSButton()
    private let forwardBtn = NSButton()
    private let progressBar = NSView()
    private let scrim = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true

        scrim.colors = [
            NSColor(white: 0, alpha: 0.45).cgColor,
            NSColor(white: 0, alpha: 0).cgColor,
            NSColor(white: 0, alpha: 0).cgColor,
            NSColor(white: 0, alpha: 0.55).cgColor
        ]
        scrim.locations = [0, 0.28, 0.66, 1]
        scrim.opacity = 0
        layer?.addSublayer(scrim)

        dress(closeBtn, "xmark", 11, round: 15, action: #selector(closeClicked))
        dress(returnBtn, "arrow.up.forward", 12, round: 15, action: #selector(returnClicked))
        dress(rewindBtn, "gobackward.15", 15, round: 19, action: #selector(rewindClicked))
        dress(pauseBtn, "pause.fill", 18, round: 25, action: #selector(pauseClicked))
        dress(forwardBtn, "goforward.15", 15, round: 19, action: #selector(forwardClicked))

        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = NSColor(red: 0.95, green: 0.26, blue: 0.21, alpha: 0.9).cgColor
        progressBar.alphaValue = 0
        addSubview(progressBar)

        buttons.forEach { $0.alphaValue = 0 }
    }

    private var buttons: [NSButton] { [closeBtn, returnBtn, rewindBtn, pauseBtn, forwardBtn] }

    private func dress(_ btn: NSButton, _ symbol: String, _ size: CGFloat, round: CGFloat, action: Selector) {
        btn.image = glyph(symbol, size)
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.imagePosition = .imageOnly
        btn.target = self
        btn.action = action
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.65).cgColor
        btn.layer?.cornerRadius = round
        addSubview(btn)
    }

    private func glyph(_ name: String, _ size: CGFloat) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let look = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        return image?.withSymbolConfiguration(look)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = bounds
        CATransaction.commit()

        closeBtn.frame = NSRect(x: 14, y: bounds.height - 44, width: 30, height: 30)
        returnBtn.frame = NSRect(x: bounds.width - 44, y: bounds.height - 44, width: 30, height: 30)

        let middle = bounds.midY - 25
        pauseBtn.frame = NSRect(x: bounds.midX - 25, y: middle, width: 50, height: 50)
        rewindBtn.frame = NSRect(x: bounds.midX - 25 - 54, y: middle + 6, width: 38, height: 38)
        forwardBtn.frame = NSRect(x: bounds.midX + 25 + 16, y: middle + 6, width: 38, height: 38)

        let clamped = max(0, min(1, progress))
        progressBar.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(clamped), height: 3)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { fade(to: 1.0) }
    override func mouseExited(with event: NSEvent) { fade(to: 0.0) }

    private func fade(to value: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            buttons.forEach { $0.animator().alphaValue = value }
            progressBar.animator().alphaValue = value
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        scrim.opacity = Float(value)
        CATransaction.commit()
    }

    @objc private func closeClicked() { onClose?() }
    @objc private func returnClicked() { onReturn?() }
    @objc private func pauseClicked() { onPlayPause?() }
    @objc private func rewindClicked() { onSkip?(-15) }
    @objc private func forwardClicked() { onSkip?(15) }
}

// MARK: - Isolate JavaScript (Proven macOS WebKit Isolation Architecture)
private enum IsolateScript {
    static let on = """
    (function () {
      var videos = document.querySelectorAll('video');
      var best = null, area = 0;
      for (var i = 0; i < videos.length; i++) {
        var v = videos[i];
        if (v.paused || v.ended || v.readyState < 2) continue;
        var box = v.getBoundingClientRect();
        if (box.width * box.height >= area) { area = box.width * box.height; best = v; }
      }
      if (!best && videos.length > 0) {
        best = videos[0];
      }
      if (!best) return 'none';

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
        'background:#000 !important; overflow:hidden !important; margin:0 !important}',
        'html.nomad-floating body > *:not(:has([data-nomad-float])) { visibility:hidden !important; display:none !important }',
        'html.nomad-floating [data-nomad-float] {',
        'visibility:visible !important; position:fixed !important;',
        'left:0 !important; top:0 !important; right:0 !important; bottom:0 !important;',
        'width:100vw !important; height:100vh !important;',
        'max-width:none !important; max-height:none !important;',
        'transform:none !important; translate:none !important; rotate:none !important; scale:none !important;',
        'opacity:1 !important; object-fit:contain !important; z-index:2147483647 !important}',
        'html.nomad-floating [data-nomad-float] ~ .player-timedtext,',
        'html.nomad-floating :has(> [data-nomad-float]) > .player-timedtext,',
        'html.nomad-floating :has([data-nomad-float]) > .player-timedtext {',
        'visibility:visible !important; z-index:2147483647 !important}',
        'html.nomad-floating body :has([data-nomad-float]) {',
        'visibility:visible !important; overflow:visible !important; background:transparent !important; border:none !important;',
        'transform:none !important; translate:none !important; rotate:none !important; scale:none !important;',
        'filter:none !important; backdrop-filter:none !important; -webkit-backdrop-filter:none !important;',
        'perspective:none !important; contain:none !important; container-type:normal !important;',
        'will-change:auto !important; content-visibility:visible !important;',
        'clip-path:none !important; mask:none !important; -webkit-mask:none !important;',
        'opacity:1 !important}',
        'html.nomad-floating [data-nomad-float]::-webkit-media-controls {',
        'display:none !important}'
      ].join('');
      document.documentElement.classList.add('nomad-floating');

      clearInterval(window.__nomadFloatWatch);
      window.__nomadFloatWatch = setInterval(function () {
        if (document.querySelector('[data-nomad-float]')) return;
        var again = null, most = 0;
        var all = document.querySelectorAll('video');
        for (var j = 0; j < all.length; j++) {
          var one = all[j];
          if (one.paused || one.ended || one.readyState < 2) continue;
          var shape = one.getBoundingClientRect();
          if (shape.width * shape.height >= most) {
            most = shape.width * shape.height;
            again = one;
          }
        }
        if (again) again.setAttribute('data-nomad-float', '');
      }, 250);

      return 'floating';
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
