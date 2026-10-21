// HUD — a small on-screen popup (like the macOS volume HUD) shown on every toggle.
//
// One borderless, non-activating panel is reused. It never takes focus and
// lets clicks pass through. It stays ~1.2s, then fades out over ~0.3s.

import Cocoa

final class HUD {
    static let shared = HUD()

    private let size = NSSize(width: 200, height: 170)
    private let visibleDuration: TimeInterval = 1.2
    private let fadeDuration: TimeInterval = 0.3

    private var panel: NSPanel?
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    private init() {}

    /// micOn: big mic symbol (green tint) vs headphones symbol.
    /// title: e.g. "Mic ON" / "Mic OFF"; subtitle: e.g. "Call mode" / "HD sound".
    func show(micOn: Bool, title: String, subtitle: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Content
        let symbol = micOn ? "mic.fill" : "headphones"
        let config = NSImage.SymbolConfiguration(pointSize: 52, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = micOn ? .systemGreen : .labelColor
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle

        // Position: centered on the screen with the mouse, ~140pt above the bottom.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 140)
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }

        // Cancel any pending fade and show at full opacity.
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // Schedule the fade-out.
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: work)
    }

    private func fadeOut() {
        guard let panel = panel, let work = hideWork else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // Only hide if show() wasn't called again during the fade.
            if !work.isCancelled { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // Blurred rounded background
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        // Labels
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        iconView.imageScaling = .scaleProportionallyUpOrDown

        // Vertical stack: icon, title, subtitle
        let stack = NSStackView(views: [iconView, titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: iconView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: blur.leadingAnchor, constant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            iconView.widthAnchor.constraint(equalToConstant: 72),
        ])
        return panel
    }
}
