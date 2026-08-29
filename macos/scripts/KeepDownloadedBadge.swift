import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fputs("usage: KeepDownloadedBadge <output.icns>\n", stderr)
    exit(EXIT_FAILURE)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

func makeBadge(size: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return nil
    }

    context.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let scale = CGFloat(size)
    let inset = scale * 0.06
    let circle = CGRect(
        x: inset,
        y: inset,
        width: scale - inset * 2,
        height: scale - inset * 2
    )
    context.setFillColor(CGColor(red: 0.54, green: 0.54, blue: 0.57, alpha: 1))
    context.fillEllipse(in: circle)

    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(max(2, scale * 0.105))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: scale * 0.5, y: scale * 0.72))
    arrow.addLine(to: CGPoint(x: scale * 0.5, y: scale * 0.38))
    arrow.move(to: CGPoint(x: scale * 0.34, y: scale * 0.52))
    arrow.addLine(to: CGPoint(x: scale * 0.5, y: scale * 0.35))
    arrow.addLine(to: CGPoint(x: scale * 0.66, y: scale * 0.52))
    context.addPath(arrow)
    context.strokePath()

    return context.makeImage()
}

func pngData(for image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil)
    else {
        throw NSError(
            domain: "CloudreveBadgeGenerator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not create PNG data destination"]
        )
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(
            domain: "CloudreveBadgeGenerator",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "could not encode PNG"]
        )
    }
    return data as Data
}

func appendUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
        data.append(contentsOf: bytes)
    }
}

// Generate an ICNS with both standard and Retina representations.
let representations: [(type: String, size: Int)] = [
    ("ic04", 16),
    ("ic11", 32),
    ("ic05", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024),
]

var elements: [(type: Data, payload: Data)] = []
for representation in representations {
    guard let image = makeBadge(size: representation.size) else {
        throw NSError(
            domain: "CloudreveBadgeGenerator",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "could not render \(representation.size)x\(representation.size) badge"
            ]
        )
    }
    elements.append(
        (Data(representation.type.utf8), try pngData(for: image)))
}

let totalLength = 8 + elements.reduce(0) { $0 + 8 + $1.payload.count }
var icns = Data("icns".utf8)
appendUInt32(UInt32(totalLength), to: &icns)
for element in elements {
    icns.append(element.type)
    appendUInt32(UInt32(8 + element.payload.count), to: &icns)
    icns.append(element.payload)
}
try icns.write(to: outputURL, options: .atomic)
