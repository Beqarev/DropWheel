import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Rotate, crop and background tricks. All on-device: Vision is the same
/// framework Photos uses for "lift subject from background".
extension Converter {

    // MARK: - Rotate (changes the original file)

    /// Turns the image 90° clockwise, in place. For JPEG/HEIC/TIFF this only flips
    /// the "orientation" tag, so the photo itself isn't re-compressed: no quality loss.
    static func rotate(_ url: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let typeID = CGImageSourceGetType(source)
        else { throw ConversionError("Can't read image") }
        let type = UTType(typeID as String) ?? .png
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".dropwheel-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        defer { try? FileManager.default.removeItem(at: temp) }

        if [.jpeg, .heic, .tiff].contains(type),
           let dest = CGImageDestinationCreateWithURL(temp as CFURL, typeID, 1, nil) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let current = props?[kCGImagePropertyOrientation] as? Int ?? 1
            // EXIF orientation after one more clockwise quarter turn.
            let next = [1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2][current] ?? 6
            let options = [kCGImageDestinationOrientation: next] as CFDictionary
            if CGImageDestinationCopyImageSource(dest, source, options, nil) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
                return url
            }
        }

        // Other formats: actually turn the pixels.
        if type == .webP {
            try ffmpeg(["-i", url.path, "-vf", "transpose=1", "-quality", "90", temp.path])
        } else {
            let canWrite = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(typeID as String)
            guard canWrite else { throw ConversionError("Can't save this format") }
            try save(rotatedClockwise(try loadImage(url)), to: temp, as: type, quality: 0.92)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        return url
    }

    private static func rotatedClockwise(_ image: CGImage) -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.translateBy(x: 0, y: CGFloat(image.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    // MARK: - Smart crop (new file)

    /// Biggest crop with the given width/height ratio, positioned over the most
    /// eye-catching part of the photo (found by Vision), e.g. "photo 1x1.jpg".
    static func smartCrop(_ url: URL, ratio: CGFloat, name: String) throws -> URL {
        let image = try loadImage(url)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        var cropW = width, cropH = width / ratio
        if cropH > height { cropH = height; cropW = height * ratio }

        let focus = subjectCenter(of: image) ?? CGPoint(x: 0.5, y: 0.5)
        let x = min(max(focus.x * width - cropW / 2, 0), width - cropW)
        let y = min(max(focus.y * height - cropH / 2, 0), height - cropH)
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: cropW, height: cropH).integral)
        else { throw ConversionError("Crop failed") }

        let (type, ext) = outputFormat(for: url)
        let out = outputURL(for: url, suffix: " \(name)", ext: ext)
        try save(cropped, to: out, as: type, quality: 0.9)
        return out
    }

    /// Centre of the area a person would look at first, as 0…1 fractions from the top-left.
    private static func subjectCenter(of image: CGImage) -> CGPoint? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let boxes = request.results?.first?.salientObjects, !boxes.isEmpty else { return nil }
        let area = boxes.map(\.boundingBox).reduce(boxes[0].boundingBox) { $0.union($1) }
        return CGPoint(x: area.midX, y: 1 - area.midY) // Vision measures from the bottom
    }

    // MARK: - Background (new file)

    /// Keeps only the subject on a transparent background, trimmed to it: "photo cutout.png".
    static func removeBackground(_ url: URL) throws -> URL {
        let image = try loadImage(url)
        let (subject, handler) = try findSubject(in: image)
        let buffer = try subject.generateMaskedImage(ofInstances: subject.allInstances, from: handler,
                                                     croppedToInstancesExtent: true)
        let out = outputURL(for: url, suffix: " cutout", ext: "png")
        try save(try render(CIImage(cvPixelBuffer: buffer)), to: out, as: .png, quality: nil)
        return out
    }

    /// Portrait-mode look: subject stays sharp, everything else is blurred. "photo blurred.jpg".
    static func blurBackground(_ url: URL) throws -> URL {
        let image = try loadImage(url)
        let (subject, handler) = try findSubject(in: image)
        let maskBuffer = try subject.generateScaledMaskForImage(forInstances: subject.allInstances, from: handler)

        let original = CIImage(cgImage: image)
        let mask = CIImage(cvPixelBuffer: maskBuffer)
            .clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: original.extent) // soften the edge
        let strength = Double(min(image.width, image.height)) * 0.02
        let blurred = original.clampedToExtent().applyingGaussianBlur(sigma: strength).cropped(to: original.extent)
        let result = original.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: blurred,
            kCIInputMaskImageKey: mask,
        ])

        let (type, ext) = outputFormat(for: url)
        let out = outputURL(for: url, suffix: " blurred", ext: ext)
        try save(try render(result.cropped(to: original.extent)), to: out, as: type, quality: 0.9)
        return out
    }

    private static func findSubject(in image: CGImage) throws -> (VNInstanceMaskObservation, VNImageRequestHandler) {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let subject = request.results?.first, !subject.allInstances.isEmpty
        else { throw ConversionError("No clear subject found") }
        return (subject, handler)
    }

    private static func render(_ image: CIImage) throws -> CGImage {
        guard let cg = CIContext().createCGImage(image, from: image.extent)
        else { throw ConversionError("Rendering failed") }
        return cg
    }

    /// Keep JPEG/PNG/HEIC as they are; anything else becomes PNG.
    private static func outputFormat(for url: URL) -> (UTType, String) {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": (.jpeg, "jpg")
        case "heic": (.heic, "heic")
        default: (.png, "png")
        }
    }
}
