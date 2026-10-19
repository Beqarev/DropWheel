import AppKit
import UniformTypeIdentifiers

/// Broad category of a dropped file, decided from its type (not just the extension).
enum FileKind {
    case image, video, audio, pdf, document, other

    init(_ url: URL) {
        if ["doc", "docx", "rtf", "odt"].contains(url.pathExtension.lowercased()) {
            self = .document; return
        }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { self = .other; return }
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .movie) { self = .video }
        else if type.conforms(to: .audio) { self = .audio }
        else { self = .other }
    }
}

/// One thing DropWheel can do to a file.
enum WheelAction: CaseIterable {
    case jpg, png, heic, webp
    case rotate, cropSquare, crop4x5, crop16x9, removeBackground, blurBackground
    case wordToPDF
    case mp4, mp3
    case compress, splitPDF

    var title: String {
        switch self {
        case .jpg: "JPG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .webp: "WebP"
        case .rotate: "Rotate"
        case .cropSquare: "1:1"
        case .crop4x5: "4:5"
        case .crop16x9: "16:9"
        case .removeBackground: "Cut out"
        case .blurBackground: "Blur BG"
        case .wordToPDF: "PDF"
        case .mp4: "MP4"
        case .mp3: Tools.ffmpeg == nil ? "M4A" : "MP3"
        case .compress: "Shrink"
        case .splitPDF: "Split"
        }
    }

    /// Shown in the centre of the wheel while hovering.
    var subtitle: String {
        switch self {
        case .jpg, .png, .heic, .webp: "Save as \(title)"
        case .rotate: "Rotate right"
        case .cropSquare: "Square crop"
        case .crop4x5: "Portrait crop"
        case .crop16x9: "Wide crop"
        case .removeBackground: "Remove background"
        case .blurBackground: "Blur background"
        case .wordToPDF: "Save as PDF"
        case .mp4: "Save as MP4"
        case .mp3: "Extract audio"
        case .compress: "Make smaller"
        case .splitPDF: "One file per page"
        }
    }

    func accepts(_ kind: FileKind) -> Bool {
        switch self {
        case .jpg, .png, .heic, .rotate, .cropSquare, .crop4x5, .crop16x9, .removeBackground, .blurBackground:
            kind == .image
        case .webp: kind == .image && Tools.ffmpeg != nil
        case .wordToPDF: kind == .document
        case .mp4: kind == .video
        case .mp3: kind == .video || kind == .audio
        case .compress: kind == .image || kind == .video || kind == .pdf
        case .splitPDF: kind == .pdf
        }
    }
}

/// One slice of the wheel. A slice either runs one action directly, or (when it has
/// several `options`) opens an outer ring to pick from, e.g. Convert → JPG/PNG/HEIC/WebP.
struct WheelSlice {
    let title: String
    let symbol: String   // SF Symbols name (Apple's built-in icon set)
    let options: [WheelAction]

    var hasRing: Bool { options.count > 1 }

    /// All slices, clockwise from the top. Only those that fit the dragged files are shown.
    private static let all: [WheelSlice] = [
        WheelSlice(title: "Convert", symbol: "photo.on.rectangle.angled", options: [.jpg, .png, .heic, .webp]),
        WheelSlice(title: "Rotate", symbol: "rotate.right", options: [.rotate]),
        WheelSlice(title: "Crop", symbol: "crop", options: [.cropSquare, .crop4x5, .crop16x9]),
        WheelSlice(title: "Cut out", symbol: "scissors", options: [.removeBackground]),
        WheelSlice(title: "Blur BG", symbol: "camera.aperture", options: [.blurBackground]),
        WheelSlice(title: "PDF", symbol: "doc.richtext", options: [.wordToPDF]),
        WheelSlice(title: "MP4", symbol: "film", options: [.mp4]),
        WheelSlice(title: WheelAction.mp3.title, symbol: "waveform", options: [.mp3]),
        WheelSlice(title: "Split", symbol: "square.split.1x2", options: [.splitPDF]),
        WheelSlice(title: "Shrink", symbol: "arrow.down.right.and.arrow.up.left", options: [.compress]),
    ]

    static func slices(for kinds: Set<FileKind>) -> [WheelSlice] {
        all.compactMap { slice in
            let usable = slice.options.filter { action in kinds.contains(where: action.accepts) }
            return usable.isEmpty ? nil : WheelSlice(title: slice.title, symbol: slice.symbol, options: usable)
        }
    }
}

/// Optional external helpers.
enum Tools {
    /// Free office suite; if installed, Word → PDF uses it (keeps pictures).
    static let libreOffice: String? = {
        let path = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    /// Used only for formats Apple can't write (WebP, MP3).
    static let ffmpeg: String? = {
        if let bundled = Bundle.main.path(forAuxiliaryExecutable: "ffmpeg") { return bundled }
        return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()
}
