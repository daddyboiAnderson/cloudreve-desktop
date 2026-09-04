import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fputs("usage: LockBadge <output.icns>\n", stderr)
    exit(EXIT_FAILURE)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

func makeBadge(size: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    let scale = CGFloat(size)
    context.clear(CGRect(x: 0, y: 0, width: scale, height: scale))
    context.setFillColor(CGColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1))
    context.fillEllipse(in: CGRect(x: scale * 0.06, y: scale * 0.06,
                                   width: scale * 0.88, height: scale * 0.88))

    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(max(2, scale * 0.105))
    context.setLineCap(.round)
    context.move(to: CGPoint(x: scale * 0.5, y: scale * 0.69))
    context.addLine(to: CGPoint(x: scale * 0.5, y: scale * 0.43))
    context.strokePath()
    context.fillEllipse(in: CGRect(x: scale * 0.445, y: scale * 0.24,
                                   width: scale * 0.11, height: scale * 0.11))
    return context.makeImage()
}

func pngData(for image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "CloudreveBadgeGenerator", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "CloudreveBadgeGenerator", code: 2)
    }
    return data as Data
}

func appendUInt32(_ value: UInt32, to data: inout Data) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

let representations: [(String, Int)] = [
    ("ic04", 16), ("ic11", 32), ("ic05", 32), ("ic12", 64),
    ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512),
    ("ic09", 512), ("ic10", 1024),
]
var elements: [(Data, Data)] = []
for (type, size) in representations {
    guard let image = makeBadge(size: size) else {
        throw NSError(domain: "CloudreveBadgeGenerator", code: 3)
    }
    elements.append((Data(type.utf8), try pngData(for: image)))
}

let totalLength = 8 + elements.reduce(0) { $0 + 8 + $1.1.count }
var icns = Data("icns".utf8)
appendUInt32(UInt32(totalLength), to: &icns)
for (type, payload) in elements {
    icns.append(type)
    appendUInt32(UInt32(8 + payload.count), to: &icns)
    icns.append(payload)
}
try icns.write(to: outputURL, options: .atomic)
