//
//  ConsoleShims.swift
//  Cartouche on the Mac
//
//  The few UIKit names the console's screens use (Shared/, the launcher's
//  own files), as AppKit has them: an image is an NSImage, and Cartouche
//  comes back to the front when the Mac makes it the active app.
//

import AppKit
import SwiftUI

typealias UIImage = NSImage

extension NSImage {
    /// The image as it is: AppKit decodes it when it first draws it.
    func byPreparingForDisplay() async -> NSImage? { self }

    /// The bitmap behind the image, as UIImage.cgImage gives it, for the
    /// memory it takes.
    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

extension Image {
    init(uiImage: NSImage) {
        self.init(nsImage: uiImage)
    }
}

/// The notifications the console reads again on: the Mac's active app is
/// the iPhone's app in front.
enum UIApplication {
    static let didBecomeActiveNotification = NSApplication.didBecomeActiveNotification
    static let didEnterBackgroundNotification = NSApplication.didResignActiveNotification
}
