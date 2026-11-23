// Uygulama ikonunu üretir: swift scripts/make-icon.swift <kaynak> <çıktı-1024.png> [kırpma-x] [kırpma-y] [kenar]
// Kaynaktan kare bir parça kırpar, macOS ikon ızgarasına (824 pt içerik, yuvarlatılmış kare, gölge) yerleştirir.
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("kullanım: make-icon.swift kaynak.png cikti.png [kirpma-x]"); exit(1)
}
let side = args.count > 5 ? Int(args[5])! : min(cg.width, cg.height)
let cropX = args.count > 3 ? Int(args[3])! : (cg.width - side) / 2
let cropY = args.count > 4 ? Int(args[4])! : (cg.height - side) / 2   // üstten
let crop = cg.cropping(to: CGRect(x: cropX, y: cropY, width: side, height: side))!

let size = 1024
let content: CGFloat = 824
let inset = (CGFloat(size) - content) / 2
let rect = CGRect(x: inset, y: inset + 10, width: content, height: content)   // gölge için biraz yukarıda
let radius = content * 0.2237                                                  // macOS ikon köşesi

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.30).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path); ctx.clip()
ctx.draw(crop, in: rect)
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("yazıldı: \(args[2])")
