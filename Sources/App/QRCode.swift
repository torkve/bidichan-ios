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
    /// The result is always dark-on-light, whatever the appearance settings
    /// say: scanners expect that contrast, and an inverted code is one many
    /// will not read at all.
    static func image(for text: String, scale: CGFloat = 10) -> UIImage? {
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

        // The generator emits one pixel per module, which would be scaled up by
        // the view with smoothing and blur the edges. Scale it here instead,
        // where the transform keeps the modules square.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
