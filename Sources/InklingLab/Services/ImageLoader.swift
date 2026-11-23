import AppKit

/// Resimleri en uzun kenarı 1024 piksel olacak şekilde küçültüp JPEG'e çevirir.
enum ImageLoader {
    static let maxSide: CGFloat = 1024

    static func attachment(from url: URL) -> ImageAttachment? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return attachment(from: image)
    }

    static func attachment(from image: NSImage) -> ImageAttachment? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: cg, size: size).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return ImageAttachment(jpegData: jpeg, pixelSize: size)
    }

    static func fromPasteboard() -> [ImageAttachment] {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.compactMap(attachment(from:))
        }
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            return images.compactMap(attachment(from:))
        }
        return []
    }
}
