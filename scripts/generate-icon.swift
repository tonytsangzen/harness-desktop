import AppKit

// Generates the DSHWebView app icon: a blue-gradient rounded square with a
// white "DS" monogram, exported as a 1024x1024 PNG (the master image).

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)

// Rounded-square mask.
let cornerRadius = CGFloat(size) * 0.225
let clipPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(clipPath)
ctx.clip()

// Vertical blue gradient background.
let colors = [
    CGColor(red: 0.30, green: 0.44, blue: 1.00, alpha: 1.0),   // top #4D70FF
    CGColor(red: 0.16, green: 0.24, blue: 0.80, alpha: 1.0),   // bottom #293DCC
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: CGFloat(size) / 2, y: CGFloat(size)), end: CGPoint(x: CGFloat(size) / 2, y: 0), options: [])

// Central monogram "DS".
let text = "DS" as NSString
let fontSize = CGFloat(size) * 0.40
let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
]
let textSize = text.size(withAttributes: attributes)
let textRect = CGRect(
    x: (CGFloat(size) - textSize.width) / 2,
    y: (CGFloat(size) - textSize.height) / 2,
    width: textSize.width,
    height: textSize.height
)
text.draw(in: textRect, withAttributes: attributes)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("failed to encode PNG")
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
