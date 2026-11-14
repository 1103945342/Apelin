import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// The sign-in code as an image: the system's QR generator draws it and the
/// page scales it up whole, so no module blurs into its neighbour. The text
/// the code carries is a sign-in secret and stays inside this call.
enum ClawBotQRCode {
    private static let context = CIContext()

    /// A square image of `text`, one module at least `pixelScale` pixels
    /// wide; nil when the generator refuses the text or the image.
    static func image(for text: String, pixelScale: CGFloat = 10) -> UIImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, pixelScale.rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
