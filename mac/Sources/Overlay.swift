import AppKit
import QuartzCore

/// The floating pill at the bottom of the screen. A non-activating panel, so it never takes focus
/// from the app you're dictating into. All methods must be called on the main thread.
final class Overlay {
    /// Mic level, 0...1. Set ~30-60x/sec while recording; the waveform eases toward it.
    var level: Float = 0

    /// The panel is a fixed, transparent strip; the pill inside it animates its own width.
    private static let panelWidth: CGFloat = 560
    private static let pillHeight: CGFloat = 36
    private static let bottomInset: CGFloat = 28

    private let panel: NSPanel
    private let pill = PillView(frame: .zero)
    private var timer: Timer?
    private var autoHide: DispatchWorkItem?
    /// Bumped on every show or hide, so a fade that finishes late can tell it was superseded.
    private var generation = 0
    /// Logical visibility. Stays false while a hide fade runs.
    private var isShown = false

    init() {
        let size = NSSize(width: Overlay.panelWidth, height: Overlay.pillHeight)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.addSubview(pill)
        panel.contentView = container
    }

    // MARK: States

    /// Compact pill with a waveform that follows `level`.
    func listening() { present(.listening) }

    /// Red pulsing dot, waveform and a one-line hint.
    func handsFree() { present(.handsFree, text: "Hands-free · Fn to finish · Esc to cancel") }

    /// Compact pill with a travelling-wave animation. No mic input.
    func transcribing() { present(.transcribing) }

    /// Brief checkmark, then fades out.
    func success() {
        present(.success)
        scheduleHide(after: 0.6)
    }

    /// Text-only pill that fades out after `seconds`.
    func message(_ text: String, seconds: Double = 2.5) {
        present(.message, text: text)
        scheduleHide(after: seconds)
    }

    /// Warning icon and text with a horizontal shake, fading out after 4 s.
    func error(_ text: String) {
        present(.error, text: text)
        pill.shake()
        scheduleHide(after: 4)
    }

    /// Fades and shrinks the pill out, then orders the panel out.
    func hide() {
        autoHide?.cancel()
        autoHide = nil
        guard isShown else { return }
        isShown = false
        generation += 1
        let gen = generation
        pill.animateOut(duration: 0.16) { [weak self] in
            guard let self = self, self.generation == gen else { return }
            self.panel.orderOut(nil)
            self.stopTimer()
        }
    }

    // MARK: Internals

    private func present(_ mode: PillView.Mode, text: String = "") {
        autoHide?.cancel()
        autoHide = nil
        generation += 1
        // macOS can order the panel out behind our back (e.g. ⌘H hides the whole app, panels
        // included), so trust the window's real visibility, not just our own flag.
        if NSApp.isHidden {
            Log.d("overlay: app was hidden, unhiding")
            NSApp.unhideWithoutActivation()
        }
        if isShown && panel.isVisible {
            pill.apply(mode, text: text, animated: true)
        } else {
            if isShown { Log.d("overlay: panel was ordered out while shown; re-presenting") }
            isShown = true
            positionPanel()
            pill.apply(mode, text: text, animated: false)
            pill.popIn()
            panel.orderFrontRegardless()
            startTimer()
        }
    }

    private func scheduleHide(after seconds: Double) {
        autoHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Centres the panel horizontally on the screen under the mouse, just above the Dock.
    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let f = screen?.visibleFrame, !f.isEmpty else { return }
        var frame = NSRect(x: f.midX - Overlay.panelWidth / 2, y: f.minY + Overlay.bottomInset,
                           width: Overlay.panelWidth, height: Overlay.pillHeight)
        // Keep the whole strip inside the visible area of that screen.
        frame.origin.x = min(max(frame.minX, f.minX), max(f.minX, f.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, f.minY), f.maxY - frame.height)
        panel.setFrame(frame, display: true)
        Log.d(String(format: "overlay at x=%.0f y=%.0f on screen %.0fx%.0f",
                     frame.minX, frame.minY, f.width, f.height))
    }

    /// Drives the waveform at 60 fps. Runs only while the overlay is visible.
    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pill.tick(level: self.level, time: CACurrentMediaTime())
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// The pill itself: a dark rounded background holding a waveform, dot, icon and/or label.
/// Changing mode animates the width and moves the contents to their new places.
fileprivate final class PillView: NSView {
    enum Mode { case listening, handsFree, transcribing, success, message, error }

    private static let height: CGFloat = 36
    private static let maxWidth: CGFloat = 520
    private static let pad: CGFloat = 14

    private let waveform = WaveformView(frame: .zero)
    private let dot = NSView(frame: .zero)
    private let icon = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.cornerRadius = PillView.height / 2

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4

        icon.imageScaling = .scaleProportionallyDown

        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true

        addSubview(waveform)
        addSubview(dot)
        addSubview(icon)
        addSubview(label)
    }

    /// Switches to `mode`, sets the text, and resizes the pill around its contents, centred in
    /// the superview. With `animated`, the width and contents glide over ~0.18 s.
    func apply(_ mode: Mode, text: String, animated: Bool) {
        let h = PillView.height
        let pad = PillView.pad
        let barsSize = WaveformView.size

        label.font = .systemFont(ofSize: mode == .handsFree ? 12 : 13, weight: .medium)
        label.stringValue = text
        let textSize = label.intrinsicContentSize

        let showsWave = mode == .listening || mode == .transcribing || mode == .handsFree
        let showsLabel = mode == .handsFree || mode == .message || mode == .error
        dot.isHidden = mode != .handsFree
        waveform.isHidden = !showsWave
        waveform.style = mode == .transcribing ? .thinking : .listening
        icon.isHidden = mode != .success && mode != .error
        label.isHidden = !showsLabel

        if mode == .success {
            icon.image = symbol("checkmark")
            icon.contentTintColor = .white
        } else if mode == .error {
            icon.image = symbol("exclamationmark.triangle.fill")
            icon.contentTintColor = .systemYellow
        }

        // Left to right: dot, waveform or icon, then the label.
        var x = pad
        var dotFrame = NSRect.zero
        var waveFrame = NSRect.zero
        var iconFrame = NSRect.zero
        switch mode {
        case .listening, .transcribing:
            waveFrame = NSRect(x: x, y: (h - barsSize.height) / 2, width: barsSize.width, height: barsSize.height)
            x += barsSize.width
        case .handsFree:
            dotFrame = NSRect(x: x, y: (h - 8) / 2, width: 8, height: 8)
            x += 8 + 8
            waveFrame = NSRect(x: x, y: (h - barsSize.height) / 2, width: barsSize.width, height: barsSize.height)
            x += barsSize.width + 10
        case .error:
            iconFrame = NSRect(x: x, y: (h - 14) / 2, width: 14, height: 14)
            x += 14 + 6
        case .success, .message:
            break
        }

        var width: CGFloat
        var labelFrame = NSRect.zero
        if showsLabel {
            let labelWidth = min(ceil(textSize.width), PillView.maxWidth - x - pad)
            width = x + labelWidth + pad
            if mode == .message { width = max(width, 60) }
            let lh = ceil(textSize.height)
            labelFrame = NSRect(x: x, y: (h - lh) / 2, width: width - x - pad, height: lh)
        } else if mode == .success {
            width = 56
            iconFrame = NSRect(x: (width - 16) / 2, y: (h - 16) / 2, width: 16, height: 16)
        } else {
            width = x + pad
        }

        let containerWidth = superview?.bounds.width ?? width
        let pillFrame = NSRect(x: (containerWidth - width) / 2, y: 0, width: width, height: h)

        // The hands-free dot breathes; stop it again when leaving that mode.
        if mode == .handsFree {
            if dot.layer?.animation(forKey: "pulse") == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.25
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.layer?.add(pulse, forKey: "pulse")
            }
        } else {
            dot.layer?.removeAnimation(forKey: "pulse")
        }

        NSAnimationContext.runAnimationGroup({ _ in
            let ctx = NSAnimationContext.current
            ctx.duration = animated ? 0.18 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            place(self, pillFrame, animated: animated)
            place(dot, dotFrame, animated: animated)
            place(waveform, waveFrame, animated: animated)
            place(icon, iconFrame, animated: animated)
            place(label, labelFrame, animated: animated)
        })
    }

    /// One horizontal shake, used for errors.
    func shake() {
        guard let layer = layer else { return }
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, -8, 8, -6, 6, -3, 3, 0].map { NSNumber(value: $0) }
        anim.duration = 0.4
        layer.add(anim, forKey: "shake")
    }

    /// Springs in from ~85% size while fading up, starting from a clean layer state.
    func popIn() {
        guard let layer = layer else { return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.85, 1.04, 0.98, 1.0].map { NSNumber(value: $0) }
        scale.keyTimes = [0.0, 0.6, 0.85, 1.0].map { NSNumber(value: $0) }
        scale.duration = 0.22
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.14
        layer.add(scale, forKey: "popScale")
        layer.add(fade, forKey: "popFade")
    }

    /// Fades and shrinks the pill out, holding the invisible end state. `completion` runs when
    /// the animation finishes.
    func animateOut(duration: CFTimeInterval, completion: @escaping () -> Void) {
        guard let layer = layer else {
            completion()
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0.0
        fade.duration = duration
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1.0
        shrink.toValue = 0.92
        shrink.duration = duration

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(fade, forKey: "fadeOut")
        layer.add(shrink, forKey: "shrink")
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
        CATransaction.commit()
    }

    /// Advances the waveform one frame.
    func tick(level: Float, time: CFTimeInterval) {
        waveform.tick(level: level, time: time)
    }

    private func place(_ view: NSView, _ rect: NSRect, animated: Bool) {
        if animated {
            view.animator().frame = rect
        } else {
            view.frame = rect
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

/// Nine rounded bars whose heights ease toward a per-frame target.
fileprivate final class WaveformView: NSView {
    enum Style { case listening, thinking }

    static let count = 9
    static let barWidth: CGFloat = 3
    static let gap: CGFloat = 3
    static let maxHeight: CGFloat = 24
    static let minHeight: CGFloat = 3

    static var size: NSSize {
        NSSize(width: CGFloat(count) * barWidth + CGFloat(count - 1) * gap, height: maxHeight)
    }

    var style: Style = .listening

    private let bars: [CALayer] = (0..<WaveformView.count).map { _ in
        let layer = CALayer()
        layer.backgroundColor = NSColor.white.cgColor
        layer.cornerRadius = WaveformView.barWidth / 2
        return layer
    }
    private var heights = [CGFloat](repeating: WaveformView.minHeight, count: WaveformView.count)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        for bar in bars {
            layer?.addSublayer(bar)
        }
    }

    /// One frame: compute each bar's target, ease toward it, then move the layers without
    /// implicit animation.
    func tick(level: Float, time: CFTimeInterval) {
        let minH = WaveformView.minHeight
        let range = Double(WaveformView.maxHeight - minH)
        // Mic levels sit low on speech, so lift them with a gentle curve.
        let amp = min(1, pow(Double(max(0, level)), 0.6) * 1.2)

        for i in 0..<WaveformView.count {
            let shape: Double
            switch style {
            case .listening:
                // Centre bars are tallest; a slight per-bar wobble keeps it organic.
                let distance = abs(Double(i) - 4) / 4
                let centre = 1 - 0.55 * pow(distance, 1.5)
                let wobble = 1 + 0.08 * sin(time * 6 + Double(i) * 1.7)
                shape = min(1, max(0, amp * centre * wobble))
            case .thinking:
                // A sine wave travelling across the bars.
                shape = 0.75 * (0.5 + 0.5 * sin(time * 2 * .pi * 1.2 - Double(i) * 0.8))
            }
            let target = minH + CGFloat(range * shape)
            let current = heights[i]
            heights[i] = current + (target - current) * (target > current ? 0.5 : 0.2)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let h = heights[i]
            bar.frame = CGRect(x: CGFloat(i) * (WaveformView.barWidth + WaveformView.gap),
                               y: (bounds.height - h) / 2, width: WaveformView.barWidth, height: h)
        }
        // Subtle opacity pulse while transcribing.
        layer?.opacity = style == .thinking ? Float(0.7 + 0.3 * sin(time * 2 * .pi * 0.8)) : 1
        CATransaction.commit()
    }
}
