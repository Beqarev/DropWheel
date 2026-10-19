import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct ConversionError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// All the actual file work. Everything runs on this Mac; nothing is uploaded.
/// Output files are written next to the originals and never overwrite anything.
enum Converter {
    struct Result {
        var outputs: [URL] = []
        var failures: [String] = []
    }

    static func run(_ action: WheelAction, on urls: [URL]) async -> Result {
        var result = Result()
        for url in urls where action.accepts(FileKind(url)) {
            do {
                result.outputs += try await convert(url, action)
            } catch {
                result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    private static func convert(_ url: URL, _ action: WheelAction) async throws -> [URL] {
        let kind = FileKind(url)
        switch action {
        case .jpg:  return [try writeImage(url, as: .jpeg, ext: "jpg", quality: 0.85)]
        case .png:  return [try writeImage(url, as: .png, ext: "png")]
        case .heic: return [try writeImage(url, as: .heic, ext: "heic", quality: 0.8)]
        case .webp: return [try webp(url)]
        case .mp4:  return [try await mp4(url)]
        case .mp3:  return [try await audio(url)]
        case .splitPDF: return try splitPDF(url)
        case .wordToPDF: return [try wordToPDF(url)]
        case .rotate: return [try rotate(url)]
        case .cropSquare: return [try smartCrop(url, ratio: 1, name: "1x1")]
        case .crop4x5: return [try smartCrop(url, ratio: 4.0 / 5.0, name: "4x5")]
        case .crop16x9: return [try smartCrop(url, ratio: 16.0 / 9.0, name: "16x9")]
        case .removeBackground: return [try removeBackground(url)]
        case .blurBackground: return [try blurBackground(url)]
        case .compress:
            let out: URL
            switch kind {
            case .image: out = try compressImage(url)
            case .video: out = try await export(url, preset: AVAssetExportPreset1280x720, suffix: "-compressed")
            case .pdf:   out = try compressPDF(url)
            default:     return []
            }
            return [try keepIfSmaller(out, than: url)]
        }
    }

    /// A "compressed" file that came out bigger than the original is useless: delete it.
    private static func keepIfSmaller(_ out: URL, than original: URL) throws -> URL {
        let size = { (u: URL) in (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        guard size(out) < size(original) else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError("Already as small as it gets")
        }
        return out
    }

    // MARK: - Images (ImageIO, built into macOS)

    /// Decodes an image, applying its EXIF rotation, optionally shrinking it.
    static func loadImage(_ url: URL, maxPixels: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw ConversionError("Can't read image") }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // bake in rotation
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels ?? .max, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw ConversionError("Can't decode image") }
        return image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    /// JPEG has no transparency; paint transparent areas white instead of black.
    private static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func save(_ image: CGImage, to out: URL, as type: UTType, quality: Double?) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil)
        else { throw ConversionError("Can't write \(type.preferredFilenameExtension ?? "file")") }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        let toWrite = (type == .jpeg && hasAlpha(image)) ? flattenedOnWhite(image) : image
        CGImageDestinationAddImage(dest, toWrite, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError("Saving failed") }
    }

    private static func writeImage(_ url: URL, as type: UTType, ext: String, quality: Double? = nil) throws -> URL {
        let image = try loadImage(url)
        let out = outputURL(for: url, ext: ext)
        try save(image, to: out, as: type, quality: quality)
        return out
    }

    /// Max 2560px on the long side, JPEG at 60% (PNG if it has transparency).
    private static func compressImage(_ url: URL) throws -> URL {
        let image = try loadImage(url, maxPixels: 2560)
        let keepPNG = hasAlpha(image) && url.pathExtension.lowercased() == "png"
        let out = outputURL(for: url, suffix: "-compressed", ext: keepPNG ? "png" : "jpg")
        try save(image, to: out, as: keepPNG ? .png : .jpeg, quality: keepPNG ? nil : 0.6)
        return out
    }

    /// macOS can read WebP but not write it, so this one goes through ffmpeg.
    private static func webp(_ url: URL) throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try save(try loadImage(url), to: temp, as: .png, quality: nil) // normalise HEIC/rotation first
        let out = outputURL(for: url, ext: "webp")
        try ffmpeg(["-i", temp.path, "-c:v", "libwebp", "-quality", "82", out.path])
        return out
    }

    // MARK: - Video & audio (AVFoundation, built into macOS)

    private static func mp4(_ url: URL) async throws -> URL {
        // Passthrough just re-packages the video without re-encoding: near-instant.
        // If the codec doesn't fit in MP4 (e.g. ProRes), fall back to re-encoding.
        if let out = try? await export(url, preset: AVAssetExportPresetPassthrough) { return out }
        return try await export(url, preset: AVAssetExportPresetHighestQuality)
    }

    private static func audio(_ url: URL) async throws -> URL {
        if Tools.ffmpeg != nil {
            // Apple has no MP3 encoder, so MP3 uses ffmpeg when it's installed.
            let out = outputURL(for: url, ext: "mp3")
            try ffmpeg(["-i", url.path, "-vn", "-c:a", "libmp3lame", "-q:a", "2", out.path])
            return out
        }
        return try await export(url, preset: AVAssetExportPresetAppleM4A, type: .m4a, ext: "m4a")
    }

    private static func export(_ url: URL, preset: String, type: AVFileType = .mp4,
                               ext: String = "mp4", suffix: String = "") async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset)
        else { throw ConversionError("Can't open media") }
        let out = outputURL(for: url, suffix: suffix, ext: ext)
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw session.error ?? ConversionError("Export failed")
        }
        return out
    }

    // MARK: - PDF (PDFKit, built into macOS)

    private static func compressPDF(_ url: URL) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ConversionError("Can't open PDF") }
        let out = outputURL(for: url, suffix: "-compressed", ext: "pdf")
        let options: [PDFDocumentWriteOption: Any] = [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true,
        ]
        guard doc.write(to: out, withOptions: options) else { throw ConversionError("Can't save PDF") }
        return out
    }

    /// "Report.pdf" -> folder "Report pages/" with "Report p1.pdf", "Report p2.pdf", …
    private static func splitPDF(_ url: URL) throws -> [URL] {
        guard let doc = PDFDocument(url: url) else { throw ConversionError("Can't open PDF") }
        let base = url.deletingPathExtension().lastPathComponent
        let folder = outputURL(for: url, suffix: " pages", ext: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var outputs: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let out = folder.appendingPathComponent("\(base) p\(i + 1).pdf")
            guard single.write(to: out) else { throw ConversionError("Can't save page \(i + 1)") }
            outputs.append(out)
        }
        return outputs
    }

    // MARK: - Helpers

    /// "photo.png" + ext "jpg" -> "photo.jpg", or "photo 2.jpg" if that already exists.
    static func outputURL(for source: URL, suffix: String = "", ext: String?) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        func make(_ name: String) -> URL {
            let u = dir.appendingPathComponent(name)
            return ext.map { u.appendingPathExtension($0) } ?? u
        }
        var candidate = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }

    static func ffmpeg(_ args: [String]) throws {
        guard let path = Tools.ffmpeg else { throw ConversionError("ffmpeg not installed") }
        try runTool(path, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + args)
    }

    /// Runs a command-line program and waits for it. Throws its error output if it fails.
    static func runTool(_ path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConversionError(message.isEmpty ? "\((path as NSString).lastPathComponent) failed" : message)
        }
    }
}
