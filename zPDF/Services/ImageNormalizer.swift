import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares image files for the PDF engine, one file per page:
/// upright JPEG/PNG files pass through untouched (JPEG data is embedded as-is);
/// HEIC/HEIF photos become high-quality JPEGs; multi-page TIFF/GIF frames
/// and other formats become PNGs. EXIF orientation is applied and the
/// source resolution (DPI) is kept so pages get their physical size.
enum ImageNormalizer {
    enum Failure: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case .unreadable(let name): "“\(name)” could not be read as an image." }
        }
    }

    static func frames(of url: URL, into directory: URL) throws -> [URL] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String? else { throw Failure.unreadable(url.lastPathComponent) }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw Failure.unreadable(url.lastPathComponent) }
        let uti = UTType(type)
        let passthrough = count == 1 && (uti?.conforms(to: .jpeg) == true || uti?.conforms(to: .png) == true)
            && orientation(source, index: 0) == 1
        if passthrough { return [url] }
        let photo = uti?.conforms(to: .heic) == true || uti?.conforms(to: .heif) == true || uti?.conforms(to: .jpeg) == true
        var outputs: [URL] = []
        for index in 0..<count {
            guard let image = upright(source, index: index) else { throw Failure.unreadable(url.lastPathComponent) }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let dpi = (properties[kCGImagePropertyDPIWidth] as? Double) ?? 72
            let stem = url.deletingPathExtension().lastPathComponent
            let target = directory.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(stem)-\(index + 1).\(photo ? "jpg" : "png")")
            guard let destination = CGImageDestinationCreateWithURL(target as CFURL,
                                                                    (photo ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil)
            else { throw Failure.unreadable(url.lastPathComponent) }
            var options: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
            if photo { options[kCGImageDestinationLossyCompressionQuality] = 0.92 }
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable(url.lastPathComponent) }
            outputs.append(target)
        }
        return outputs
    }

    private static func orientation(_ source: CGImageSource, index: Int) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyOrientation] as? Int) ?? 1
    }

    /// Full-resolution frame with EXIF orientation applied.
    private static func upright(_ source: CGImageSource, index: Int) -> CGImage? {
        guard orientation(source, index: index) != 1 else { return CGImageSourceCreateImageAtIndex(source, index, nil) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1)]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// Writes a CGImage (e.g. a scan or a cleaned page) as PNG or JPEG.
    @discardableResult
    static func write(_ image: CGImage, to url: URL, jpeg: Bool, dpi: Double = 300, quality: Double = 0.9) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil)
        else { return false }
        var options: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if jpeg { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
