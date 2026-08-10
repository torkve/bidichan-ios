import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Renders a profile link as a scannable code, for handing a profile to a
/// device that is in the room rather than on the other end of a chat.
///
/// Each platform uses its own encoder — this one is built into the system, and
/// the Android client uses the standard library there. That is a deliberate
/// departure from the rule that the link *format* lives in the shared core: a
/// QR code is a public standard, so two encoders cannot drift into producing
/// something the other cannot read, which is the only reason the format itself
/// is shared.
enum QRCode {

    /// The most a QR code can hold in byte mode: version 40 at the lowest
    /// error-correction level. Both clients use that level and check against
    /// this same figure, so a profile that shows a code on one shows one on the
    /// other.
    static let capacity = 2953

    /// A code for `text`, or nil if it will not fit or the encoder refuses it.
    ///
    /// The result is opaque, dark-on-light and carries its own quiet zone,
    /// whatever the appearance settings say. That matters more here than it
    /// looks: this same image is what gets shared, so it has to be scannable
    /// standing alone in someone else's chat app, where nothing this app does
    /// can put a white card behind it.
    ///
    /// - Parameters:
    ///   - scale: points per module.
    ///   - quietZone: the blank margin, in modules. Four is what the standard
    ///     asks for, and scanners do rely on it.
    static func image(for text: String, scale: CGFloat = 10, quietZone: CGFloat = 4) -> UIImage? {
        let data = Data(text.utf8)
        guard data.count <= capacity else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        // "L" spends the fewest modules on recovery, which is what makes room
        // for a profile carrying a certificate. A code shown on a screen and
        // scanned from a few centimetres away is not the case error correction
        // is there for.
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }

        // The generator emits one pixel per module. Scale it here, where the
        // transform keeps the modules square, rather than letting a view scale
        // it up and blur the edges.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        let margin = quietZone * scale
        let side = scaled.extent.width + margin * 2
        let format = UIGraphicsImageRendererFormat()
        // One pixel per point: the code is already at its final size, and
        // letting the renderer apply the screen's scale would only resample it.
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                       format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            // Nearest neighbour, so the module edges stay hard.
            ctx.cgContext.interpolationQuality = .none
            UIImage(cgImage: cgImage).draw(in: CGRect(x: margin, y: margin,
                                                      width: scaled.extent.width,
                                                      height: scaled.extent.height))
        }
    }
}
