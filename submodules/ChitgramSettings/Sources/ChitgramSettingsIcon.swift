import Foundation
import UIKit
import Display
import AppBundle

/// The colours of row icons: Telegram's Settings palette (`PresentationResourcesSettings`), which is iOS's own.
public enum ChitgramIconColor {
    public static let red = UIColor(rgb: 0xFF453A)
    public static let green = UIColor(rgb: 0x34C759)
    public static let blue = UIColor(rgb: 0x0A84FF)
    public static let lightBlue = UIColor(rgb: 0x32ADE6)
    public static let teal = UIColor(rgb: 0x00C7BE)
    public static let orange = UIColor(rgb: 0xFF9F0A)
    public static let purple = UIColor(rgb: 0xAF52DE)
    public static let pink = UIColor(rgb: 0xFF2D55)
    public static let gray = UIColor(rgb: 0x8E8E93)
    public static let violet = UIColor(rgb: 0x5E5CE6)
}

private let chitgramIconGloss = UIImage(bundleImageName: "Item List/Icons/Gradient")
private let chitgramIconBackdrop = UIImage(bundleImageName: "Item List/Icons/Backdrop")

private final class ChitgramIconCache {
    let lock = NSLock()
    var images: [String: UIImage] = [:]
}

private let chitgramIconCache = ChitgramIconCache()

/// A row icon drawn the way Telegram draws the Settings tab's icons (`renderSettingsIcon`): a 30×30 tile of one colour
/// under Telegram's gloss and backdrop, 8 pt corners and a white glyph. The glyph is an SF Symbol, so that every
/// Chitgram row can have an icon of its own meaning and still look like the rows of the Settings tab. Images are kept,
/// since list rows ask for their icon on every update.
public func chitgramSettingsIcon(systemName: String, color: UIColor) -> UIImage? {
    var red: CGFloat = 0.0
    var green: CGFloat = 0.0
    var blue: CGFloat = 0.0
    var alpha: CGFloat = 0.0
    _ = color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let key = "\(systemName)|\(Int(red * 255.0))|\(Int(green * 255.0))|\(Int(blue * 255.0))"

    chitgramIconCache.lock.lock()
    let cached = chitgramIconCache.images[key]
    chitgramIconCache.lock.unlock()
    if let cached {
        return cached
    }

    let mask = chitgramIconGlyph(systemName: systemName)?.cgImage
    let image = generateImage(CGSize(width: 30.0, height: 30.0), contextGenerator: { size, context in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.clear(bounds)

        context.setFillColor(color.cgColor)
        context.fill(bounds)

        if let cgImage = chitgramIconGloss?.cgImage {
            context.setBlendMode(.plusLighter)
            context.draw(cgImage, in: bounds)
        }
        if let cgImage = chitgramIconBackdrop?.cgImage {
            context.setBlendMode(.overlay)
            context.draw(cgImage, in: bounds)
        }
        context.setBlendMode(.normal)

        if let mask {
            context.saveGState()
            context.clip(to: bounds, mask: mask)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(bounds)
            context.restoreGState()
        }

        let outerPath = UIBezierPath(rect: bounds)
        outerPath.append(UIBezierPath(roundedRect: bounds, cornerRadius: 8.0))
        outerPath.usesEvenOddFillRule = true
        context.saveGState()
        context.addPath(outerPath.cgPath)
        context.clip(using: .evenOdd)
        context.setBlendMode(.clear)
        context.fill(bounds)
        context.restoreGState()
    })

    if let image {
        chitgramIconCache.lock.lock()
        chitgramIconCache.images[key] = image
        chitgramIconCache.lock.unlock()
    }
    return image
}

/// The glyph alone, white on a clear 30×30 square, at most 20 points either way: Telegram's glyphs are drawn on
/// a 30×30 canvas too, so the tile uses it as its mask in the same way.
private func chitgramIconGlyph(systemName: String) -> UIImage? {
    let configuration = UIImage.SymbolConfiguration(pointSize: 16.0, weight: .semibold)
    guard let symbol = UIImage(systemName: systemName, withConfiguration: configuration) else {
        return nil
    }
    let size = CGSize(width: 30.0, height: 30.0)
    let longest = max(symbol.size.width, symbol.size.height)
    let scale = longest > 20.0 ? 20.0 / longest : 1.0
    let drawSize = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
    let format = UIGraphicsImageRendererFormat.preferred()
    format.opaque = false
    // 8 bits a channel, as the mask is read the way Telegram reads its own glyph images.
    format.preferredRange = .standard
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        let rect = CGRect(x: (size.width - drawSize.width) / 2.0, y: (size.height - drawSize.height) / 2.0, width: drawSize.width, height: drawSize.height)
        symbol.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: rect)
    }
}
