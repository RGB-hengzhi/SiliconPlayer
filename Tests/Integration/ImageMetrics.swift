import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

@main struct ImageMetrics {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        var difference = 0
        let hash = try bytes.withUnsafeMutableBytes { buffer -> String in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileReadCorruptFile) }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = buffer.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                difference = max(difference, abs(Int(pixels[index]) - Int(pixels[index + 1])), abs(Int(pixels[index]) - Int(pixels[index + 2])))
            }
            return SHA256.hash(data: Data(buffer)).map { String(format: "%02x", $0) }.joined()
        }
        let output: [String: Any] = ["width": image.width, "height": image.height, "pixelSHA256": hash, "maxChannelDifference": difference,
                                    "imageType": CGImageSourceGetType(source).map { $0 as String } ?? ""]
        print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
