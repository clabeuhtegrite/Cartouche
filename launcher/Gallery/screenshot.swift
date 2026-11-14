//
//  screenshot.swift
//  The launcher's gallery, on the Mac that takes its screens (capture.sh)
//
//  Cuts a scenario's screen out of the simulator's screenshot, or turns it
//  the right way up. The simulator's screenshot is its screen as it sits in
//  the device, upright, even when the gallery has turned itself sideways.
//
//      screenshot RAW READY OUT [WIDTH HEIGHT]
//
//  READY is what the gallery wrote once its screen had settled
//  (tmp/ready-<scenario>.json in its container): the screen's scale, where
//  its window sits and which way it is turned. With WIDTH and HEIGHT, in
//  points, the scenario's screen is the one drawn in the window's top left
//  corner, upright.
//
//  It prints the screen's signature (Signature below), from which capture.sh
//  tells whether the simulator shows the gallery drawn and still, or iOS
//  still opening it (settled.py).
//

import CoreGraphics
import Foundation
import ImageIO

struct Ready: Decodable {
    let scale: Double
    /// The window's top left corner on the screen, in points.
    let origin: [Double]
    /// portrait, portraitUpsideDown, landscapeLeft or landscapeRight.
    let orientation: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("screenshot: \(message)\n".utf8))
    exit(1)
}

/// IMAGE a quarter turn clockwise, or anticlockwise.
func turned(_ image: CGImage, clockwise: Bool) -> CGImage? {
    let width = image.width, height = image.height
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: height, height: width, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    if clockwise {
        context.translateBy(x: 0, y: CGFloat(width))
        context.rotate(by: -.pi / 2)
    } else {
        context.translateBy(x: CGFloat(height), y: 0)
        context.rotate(by: .pi / 2)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

/// The screen cut into COLUMNS x ROWS cells, row by row, with each cell's
/// mean luminance, from 0 to 255, and how far apart its darkest and lightest
/// pixels are: what capture.sh compares from one screenshot to the next
/// (settled.py).
struct Signature: Encodable {
    let columns: Int
    let rows: Int
    let means: [Double]
    let spreads: [Int]
}

/// IMAGE's signature, over black as the corners its display's mask leaves
/// out, in sRGB.
func signature(of image: CGImage, columns: Int = 16, rows: Int = 16) -> Signature? {
    let width = image.width, height = image.height
    guard width >= columns, height >= rows, let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = context.data else {
        return nil
    }
    context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    let cells = columns * rows
    var sums = [Int](repeating: 0, count: cells), counts = [Int](repeating: 0, count: cells)
    var lows = [Int](repeating: 255, count: cells), highs = [Int](repeating: 0, count: cells)
    for y in 0..<height {
        let row = y * rows / height * columns
        for x in 0..<width {
            let pixel = (y * width + x) * 4
            let red = Int(pixels[pixel]), green = Int(pixels[pixel + 1]), blue = Int(pixels[pixel + 2])
            let luminance = (2126 * red + 7152 * green + 722 * blue) / 10_000
            let cell = row + x * columns / width
            sums[cell] += luminance
            counts[cell] += 1
            lows[cell] = min(lows[cell], luminance)
            highs[cell] = max(highs[cell], luminance)
        }
    }
    return Signature(columns: columns, rows: rows,
                     means: (0..<cells).map { (Double(sums[$0]) / Double(counts[$0]) * 10).rounded() / 10 },
                     spreads: (0..<cells).map { highs[$0] - lows[$0] })
}

let arguments = CommandLine.arguments
guard arguments.count == 4 || arguments.count == 6 else {
    fail("usage: screenshot RAW READY OUT [WIDTH HEIGHT]")
}
let ready: Ready
do {
    ready = try JSONDecoder().decode(Ready.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
} catch {
    fail("cannot read \(arguments[2]): \(error)")
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot read \(arguments[1])")
}

var screen = image
if arguments.count == 6 {
    guard let width = Double(arguments[4]), let height = Double(arguments[5]), ready.origin.count == 2 else {
        fail("no size in \(arguments[4]) x \(arguments[5]), or no window in \(arguments[2])")
    }
    let rect = CGRect(x: (ready.origin[0] * ready.scale).rounded(), y: (ready.origin[1] * ready.scale).rounded(),
                      width: (width * ready.scale).rounded(), height: (height * ready.scale).rounded())
    guard let cut = image.cropping(to: rect), cut.width == Int(rect.width), cut.height == Int(rect.height) else {
        fail("cannot cut \(rect) out of \(image.width) x \(image.height)")
    }
    screen = cut
} else if ready.orientation.hasPrefix("landscape"), image.width < image.height {
    // Turned back against the gallery's turn: landscapeRight has the top of
    // the gallery along the right side of the upright screenshot.
    guard let upright = turned(image, clockwise: ready.orientation == "landscapeLeft") else {
        fail("cannot turn \(arguments[1])")
    }
    screen = upright
}

guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[3]) as CFURL,
                                                        "public.png" as CFString, 1, nil) else {
    fail("cannot write \(arguments[3])")
}
CGImageDestinationAddImage(destination, screen, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("cannot write \(arguments[3])")
}
guard let found = signature(of: screen), let json = try? JSONEncoder().encode(found) else {
    fail("cannot read the screen of \(arguments[1])")
}
print(String(decoding: json, as: UTF8.self))
