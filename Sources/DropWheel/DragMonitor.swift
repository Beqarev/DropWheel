import AppKit

/// Watches the whole system for "the user is dragging files while holding Shift".
///
/// It only listens to *mouse* events. macOS lets any app observe global mouse
/// events without Accessibility permission (only keyboard events need it), and
/// we read the Shift key from `NSEvent.modifierFlags`, which is also allowed.
/// So the app needs no permission prompt at all.
///
/// Cost when idle: zero. macOS calls us only when the mouse is pressed or dragged.
@MainActor
final class DragMonitor {
    /// Which key must be held. Shift doesn't change Finder's drag behaviour, so it's a safe default.
    var modifier: NSEvent.ModifierFlags = .shift

    private let onTrigger: (NSPoint, [URL]) -> Void
    private var monitors: [Any] = []
    private var pasteboardCountAtMouseDown = 0
    private var firedThisDrag = false

    init(onTrigger: @escaping (NSPoint, [URL]) -> Void) {
        self.onTrigger = onTrigger
    }

    func start() {
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.mouseDown() },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in self?.mouseDragged() },
        ].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func mouseDown() {
        firedThisDrag = false
        // The "drag pasteboard" is where apps put what's being dragged. Remember
        // its counter now; if it changes during this mouse press, a real drag began.
        pasteboardCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    }

    private func mouseDragged() {
        guard !firedThisDrag, NSEvent.modifierFlags.contains(modifier) else { return }

        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != pasteboardCountAtMouseDown else { return }
        // Something new is being dragged. Is it files (not text, not a window)?
        let files = pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !files.isEmpty else {
            pasteboardCountAtMouseDown = pasteboard.changeCount // don't re-check this drag
            return
        }

        firedThisDrag = true
        onTrigger(NSEvent.mouseLocation, files)
    }
}
