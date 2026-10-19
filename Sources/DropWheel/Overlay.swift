import AppKit
import Combine
import SwiftUI

/// Shared state between the AppKit drop logic and the SwiftUI drawing.
/// When a @Published value changes, SwiftUI redraws the wheel automatically.
final class WheelModel: ObservableObject {
    enum Status: Equatable { case working, done, failed(Int) }

    @Published var slices: [WheelSlice] = []
    @Published var hotSlice: Int?    // slice under the cursor
    @Published var hotOption: Int?   // choice in the outer ring under the cursor
    @Published var fileCount = 0
    @Published var status: Status?

    var busy: Bool { status == .working }

    /// What would happen if the user let go right now.
    var selectedAction: WheelAction? {
        guard let s = hotSlice else { return nil }
        let slice = slices[s]
        if !slice.hasRing { return slice.options[0] }
        return hotOption.map { slice.options[$0] }
    }

    /// Picks the slices that make sense for these files.
    func load(_ files: [URL]) {
        slices = WheelSlice.slices(for: Set(files.map(FileKind.init)))
        fileCount = files.count
        hotSlice = nil; hotOption = nil; status = nil
    }
}

/// Creates the floating transparent window once, then shows/hides it per drag.
@MainActor
final class OverlayController {
    private let model = WheelModel()
    private let panel: NSPanel
    private let container: NSView
    private let glass: NSVisualEffectView
    private var mouseUpTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var isPreview = false

    init() {
        let size = WheelGeometry.size
        let frame = NSRect(x: 0, y: 0, width: size, height: size)
        panel = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel], // never steals focus from Finder
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true                                     // system shadow, follows the wheel's shape
        panel.level = .floating   // above normal windows, but below system prompts
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        // The same frosted glass macOS uses for menus and popovers. It blurs whatever
        // is behind the window and adapts to light/dark mode by itself.
        glass = NSVisualEffectView(frame: frame)
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.autoresizingMask = [.width, .height]

        let wheel = PassthroughHostingView(rootView: WheelView(model: model))
        wheel.frame = frame
        wheel.autoresizingMask = [.width, .height]

        // Holds glass + drawing so they can "pop" in together.
        container = NSView(frame: frame)
        container.wantsLayer = true
        container.addSubview(glass)
        container.addSubview(wheel)

        let dropView = DropView(frame: frame, model: model)
        dropView.onDrop = { [weak self] action, urls in self?.run(action, on: urls) }
        dropView.addSubview(container)
        panel.contentView = dropView

        // Reshape the glass whenever the outer ring opens or closes.
        model.$hotSlice.combineLatest(model.$slices)
            .sink { [weak self] hot, slices in self?.updateGlassShape(slices: slices, hot: hot) }
            .store(in: &subscriptions)
    }

    func show(at point: NSPoint, for files: [URL]) {
        guard !panel.isVisible else { return }
        model.load(files)
        guard !model.slices.isEmpty else { return } // nothing we can do with these files
        let half = WheelGeometry.size / 2
        panel.setFrameOrigin(NSPoint(x: point.x - half, y: point.y - half))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        popIn()
        // While visible, check ~10x/second whether the user let go of the mouse
        // somewhere else. Runs only while the wheel is on screen.
        mouseUpTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPreview, NSEvent.pressedMouseButtons & 1 == 0,
                      self.model.status == nil else { return }
                self.hide()
            }
        }
    }

    func hide() {
        mouseUpTimer?.invalidate()
        mouseUpTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
        })
    }

    /// Dev only: show the wheel in a given state, for screenshots.
    func preview(at point: NSPoint, files: [URL], hotSlice: Int?, hotOption: Int?) {
        isPreview = true
        show(at: point, for: files)
        model.hotSlice = hotSlice
        model.hotOption = hotOption
    }

    /// Dev only: saves a picture of the wheel window (an app may always capture its own windows).
    func capture(to path: String) {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         "public.png" as CFString, 1, nil)
        else { print("capture failed"); return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// A quick spring "pop" from slightly smaller, like macOS HUDs.
    private func popIn() {
        guard let layer = container.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: container.frame.midX, y: container.frame.midY)
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.85
        spring.toValue = 1
        spring.stiffness = 320
        spring.damping = 22
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
    }

    private func updateGlassShape(slices: [WheelSlice], hot: Int?) {
        glass.maskImage = WheelGeometry.maskImage(slices: slices, hot: hot)
        panel.invalidateShadow()
    }

    private func run(_ action: WheelAction, on urls: [URL]) {
        model.status = .working
        Task {
            // Converter.run does its work in the background; we come back here when it's done.
            let result = await Converter.run(action, on: urls)
            model.status = result.failures.isEmpty ? .done : .failed(result.failures.count)
            result.failures.forEach { print("DropWheel:", $0) }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            try? await Task.sleep(for: .seconds(result.failures.isEmpty ? 0.7 : 1.8))
            hide()
        }
    }
}

/// The view that receives the dropped files and figures out which slice is under the cursor.
final class DropView: NSView {
    private let model: WheelModel
    var onDrop: ((WheelAction, [URL]) -> Void)?

    init(frame: NSRect, model: WheelModel) {
        self.model = model
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHighlight(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHighlight(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model.hotSlice = nil
        model.hotOption = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let action = model.selectedAction else { return false }
        onDrop?(action, fileURLs(sender))
        return true
    }

    private func updateHighlight(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !model.busy else { return [] }
        typealias G = WheelGeometry
        let (radius, angle) = G.polar(convert(sender.draggingLocation, from: nil), in: bounds)
        let count = model.slices.count
        var slice = model.hotSlice
        var option: Int?

        if radius < G.inner {
            slice = nil                                         // centre = cancel
        } else if radius <= G.outer + 3 {
            slice = G.sliceIndex(at: angle, count: count)       // on a main slice
        } else if let s = slice, model.slices[s].hasRing, radius <= G.ringOuter + 24 {
            option = G.optionIndex(at: angle, count: model.slices[s].options.count,
                                   around: G.sliceAngle(s, count: count))
        }
        // Outside everything: keep the last slice, so its ring stays open.

        let before = model.selectedAction
        if model.hotSlice != slice { model.hotSlice = slice }
        if model.hotOption != option { model.hotOption = option }
        if model.selectedAction != nil, model.selectedAction != before {
            // A tiny "click" on Force Touch trackpads when landing on a new choice.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        // .copy = "the original file stays where it is" (Finder won't move it).
        return model.selectedAction == nil ? [] : .copy
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

/// SwiftUI view inside AppKit that ignores the mouse, so drops reach DropView underneath.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        unregisterDraggedTypes()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
