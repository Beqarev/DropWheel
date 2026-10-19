import AppKit
import SwiftUI

/// Terminal-only helpers for development. The normal app never uses these.
///
///   DropWheel --convert <action> file1 file2 …      (actions: see `names` below)
///   DropWheel --preview [image|video|pdf|document] [slice] [option]  (shows the real window for 6 s)
///   DropWheel --snapshot out.png [image|video|pdf|document]   (renders the wheel to an image)
enum DevCommands {
    @MainActor static func handle(_ args: [String]) -> Bool {
        if args.count >= 2, args[1] == "--preview" {
            let ext = ["image": "jpg", "video": "mov", "pdf": "pdf", "document": "docx"][args.count > 2 ? args[2] : "image"] ?? "jpg"
            let slice = args.count > 3 ? Int(args[3]) : 0
            let option = args.count > 4 ? Int(args[4]) : nil
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            if let look = ProcessInfo.processInfo.environment["DROPWHEEL_APPEARANCE"] {
                app.appearance = NSAppearance(named: look == "light" ? .aqua : .darkAqua)
            }
            let overlay = OverlayController()
            let screen = NSScreen.main!.frame
            overlay.preview(at: NSPoint(x: screen.midX, y: screen.midY),
                            files: [URL(fileURLWithPath: "/preview.\(ext)")], hotSlice: slice, hotOption: option)
            if let path = ProcessInfo.processInfo.environment["DROPWHEEL_CAPTURE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { overlay.capture(to: path); exit(0) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
            app.run()
        }
        guard args.count >= 3 else { return false }
        switch args[1] {
        case "--convert":
            let names: [String: WheelAction] = [
                "jpg": .jpg, "png": .png, "heic": .heic, "webp": .webp,
                "mp4": .mp4, "mp3": .mp3, "compress": .compress, "split": .splitPDF,
                "pdf": .wordToPDF, "rotate": .rotate, "crop1x1": .cropSquare, "crop4x5": .crop4x5,
                "crop16x9": .crop16x9, "cutout": .removeBackground, "blur": .blurBackground,
            ]
            guard let action = names[args[2]] else { print("Unknown action \(args[2])"); return true }
            let urls = args.dropFirst(3).map { URL(fileURLWithPath: $0) }
            let done = DispatchSemaphore(value: 0)
            Task.detached { // off the main thread, which is blocked waiting below
                let result = await Converter.run(action, on: urls)
                result.outputs.forEach { print("✓", $0.path) }
                result.failures.forEach { print("✗", $0) }
                done.signal()
            }
            done.wait()
            return true

        case "--snapshot":
            let model = WheelModel()
            let kinds: [String: FileKind] = ["image": .image, "video": .video, "pdf": .pdf, "document": .document]
            model.slices = WheelSlice.slices(for: [kinds[args.count > 3 ? args[3] : "image"] ?? .image])
            model.fileCount = 1
            model.hotSlice = 0
            model.hotOption = model.slices[0].hasRing ? 1 : nil
            let renderer = ImageRenderer(content: WheelView(model: model))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                             "public.png" as CFString, 1, nil)
            else { print("Render failed"); return true }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            return true

        default:
            return false
        }
    }
}
