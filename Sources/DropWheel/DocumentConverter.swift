import AppKit

extension Converter {
    /// Word (.doc/.docx), RTF or OpenDocument -> PDF. No window ever appears.
    ///
    /// If the free LibreOffice is installed it's used (in the background), since it also
    /// keeps pictures, headers and footers. Otherwise macOS's built-in document reader is
    /// used: instant, and handles text, styles and tables, but skips pictures.
    static func wordToPDF(_ url: URL) throws -> URL {
        if let soffice = Tools.libreOffice {
            return try libreOfficePDF(url, soffice: soffice)
        }
        return try builtInPDF(url)
    }

    private static func libreOfficePDF(_ url: URL, soffice: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try runTool(soffice, ["--headless", "--convert-to", "pdf", "--outdir", tempDir.path, url.path])
        let made = tempDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
        let out = outputURL(for: url, ext: "pdf")
        try FileManager.default.moveItem(at: made, to: out)
        return out
    }

    private static func builtInPDF(_ url: URL) throws -> URL {
        var info: NSDictionary?
        let text = try NSAttributedString(url: url, options: [:], documentAttributes: &info)
        let attributes = info as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]

        // Page size and margins from the document itself, else A4 with ~2.5 cm margins.
        let paper = (attributes[.paperSize] as? NSValue)?.sizeValue ?? CGSize(width: 595, height: 842)
        let page = paper.width > 100 && paper.height > 100 ? paper : CGSize(width: 595, height: 842)
        func margin(_ key: NSAttributedString.DocumentAttributeKey) -> CGFloat {
            (attributes[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 72
        }
        let left = margin(.leftMargin), right = margin(.rightMargin)
        let top = margin(.topMargin), bottom = margin(.bottomMargin)
        let textArea = CGSize(width: page.width - left - right, height: page.height - top - bottom)

        // Flow the text into as many page-sized boxes as it needs.
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var pages: [NSTextContainer] = []
        repeat {
            let box = NSTextContainer(size: textArea)
            box.lineFragmentPadding = 0
            layout.addTextContainer(box)
            pages.append(box)
        } while NSMaxRange(layout.glyphRange(for: pages.last!)) < layout.numberOfGlyphs && pages.count < 2000

        // Draw each box onto a PDF page.
        let out = outputURL(for: url, ext: "pdf")
        var mediaBox = CGRect(origin: .zero, size: page)
        guard let pdf = CGContext(out as CFURL, mediaBox: &mediaBox, nil)
        else { throw ConversionError("Can't create PDF") }
        for box in pages {
            pdf.beginPDFPage(nil)
            pdf.translateBy(x: 0, y: page.height)  // text is laid out top-down; PDF is bottom-up
            pdf.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: true)
            let range = layout.glyphRange(for: box)
            let origin = CGPoint(x: left, y: top)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return out
    }
}
