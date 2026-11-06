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
