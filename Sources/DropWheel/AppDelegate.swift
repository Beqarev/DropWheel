import AppKit
import ServiceManagement

/// Owns the three long-lived pieces: the menu bar icon, the drag monitor and the wheel overlay.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayController()
    private lazy var dragMonitor = DragMonitor { [weak self] point, files in
        self?.overlay.show(at: point, for: files)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle",
                                           accessibilityDescription: "DropWheel")
        statusItem.menu = makeMenu()
        dragMonitor.start()
        askForFolderAccess()
    }

    /// macOS asks once before an app may save into Desktop, Documents or Downloads.
    /// Touch those folders at launch so the questions appear now, not in the middle of a drag.
    private func askForFolderAccess() {
        DispatchQueue.global(qos: .utility).async {
            for folder in [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory] {
                if let url = FileManager.default.urls(for: folder, in: .userDomainMask).first {
                    _ = try? FileManager.default.contentsOfDirectory(atPath: url.path)
                }
            }
        }
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let hint = NSMenuItem(title: "Hold ⇧ Shift while dragging files", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        let ffmpegNote = NSMenuItem(
            title: Tools.ffmpeg == nil ? "ffmpeg not found: WebP/MP3 disabled" : "ffmpeg found: WebP/MP3 enabled",
            action: nil, keyEquivalent: "")
        ffmpegNote.isEnabled = false
        menu.addItem(ffmpegNote)

        let wordNote = NSMenuItem(
            title: Tools.libreOffice == nil ? "Word → PDF: built-in (no pictures)" : "Word → PDF: LibreOffice",
            action: nil, keyEquivalent: "")
        wordNote.isEnabled = false
        menu.addItem(wordNote)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DropWheel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func toggleLaunchAtLogin(_ item: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSSound.beep()
        }
        item.state = service.status == .enabled ? .on : .off
    }
}
