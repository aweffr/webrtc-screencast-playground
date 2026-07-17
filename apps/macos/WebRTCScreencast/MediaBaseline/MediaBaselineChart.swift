import AppKit
import CoreGraphics
import Foundation

enum MediaBaselineLayout {
    static let canvasWidth = 1_920
    static let canvasHeight = 1_080
    static let markerROI = CGRect(x: 64, y: 64, width: 192, height: 192)
    static let qualitySampleSequences: Set<UInt32> = [1, 4, 8, 30, 80, 130]
}

struct MediaBaselineChartImage: Sendable {
    let width: Int
    let height: Int
    var bgra: [UInt8]

    func lumaBytes() -> [UInt8] {
        stride(from: 0, to: bgra.count, by: 4).map { offset in
            let blue = 29 * Int(bgra[offset])
            let green = 150 * Int(bgra[offset + 1])
            let red = 77 * Int(bgra[offset + 2])
            return UInt8((blue + green + red) >> 8)
        }
    }

    func makeCGImage() -> CGImage {
        let data = Data(bgra) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .relativeColorimetric
        )!
    }

    func pngData() -> Data? {
        NSBitmapImageRep(cgImage: makeCGImage()).representation(using: .png, properties: [:])
    }
}

enum MediaBaselineChart {
    private static let baseBGRA = makeBase()

    static func render(sequence: UInt32) -> MediaBaselineChartImage {
        let width = MediaBaselineLayout.canvasWidth
        let height = MediaBaselineLayout.canvasHeight
        var bytes = baseBGRA
        drawMarker(sequence: sequence, into: &bytes, width: width)
        return MediaBaselineChartImage(width: width, height: height, bgra: bytes)
    }

    private static func makeBase() -> [UInt8] {
        let width = MediaBaselineLayout.canvasWidth
        let height = MediaBaselineLayout.canvasHeight
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        fill(&bytes, width: width, rect: CGRect(x: 0, y: 0, width: width, height: height), color: (28, 28, 28))

        for x in 320..<1_856 {
            let value = UInt8((x - 320) * 255 / 1_535)
            fill(&bytes, width: width, rect: CGRect(x: x, y: 80, width: 1, height: 96), color: (value, value, value))
        }
        let colors: [(UInt8, UInt8, UInt8)] = [
            (235, 64, 52), (52, 168, 83), (66, 133, 244), (251, 188, 5),
            (188, 71, 222), (32, 201, 151), (245, 245, 245), (8, 8, 8),
        ]
        for (index, color) in colors.enumerated() {
            fill(&bytes, width: width, rect: CGRect(x: 320 + index * 192, y: 224, width: 160, height: 112), color: color)
        }
        for lineWidth in [1, 2, 4] {
            for offset in stride(from: 0, to: 320, by: 16) {
                fill(&bytes, width: width, rect: CGRect(x: 320 + offset, y: 400 + lineWidth * 72, width: lineWidth, height: 220), color: (240, 240, 240))
            }
            for offset in stride(from: 0, to: 220, by: 16) {
                fill(&bytes, width: width, rect: CGRect(x: 680, y: 400 + lineWidth * 72 + offset, width: 320, height: lineWidth), color: (240, 240, 240))
            }
        }
        for y in 720..<1_016 {
            for x in 320..<1_856 {
                let checker = ((x - 320) / 8 + (y - 720) / 8) % 2 == 0
                let base = UInt8((x - 320) * 180 / 1_535 + 36)
                let value = checker ? base : UInt8(max(0, Int(base) - 28))
                setPixel(&bytes, width: width, x: x, y: y, color: (value, value, value))
            }
        }

        drawText(into: &bytes, width: width, height: height)
        return bytes
    }

    private static func drawMarker(sequence: UInt32, into bytes: inout [UInt8], width: Int) {
        let roi = MediaBaselineLayout.markerROI
        let marker = MediaBaselineMarker(sequence: sequence).makeLumaImage(cellSize: Int(roi.width) / MediaBaselineMarker.gridSize)
        for y in 0..<marker.height {
            for x in 0..<marker.width {
                let value = marker.bytes[y * marker.bytesPerRow + x]
                setPixel(&bytes, width: width, x: Int(roi.minX) + x, y: Int(roi.minY) + y, color: (value, value, value))
            }
        }
    }

    private static func drawText(into bytes: inout [UInt8], width: Int, height: Int) {
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            let text = "WebRTC 屏幕投送  AaBb 0123456789"
            context.setTextDrawingMode(.fill)
            context.setFillColor(CGColor(gray: 0.94, alpha: 1))
            for (index, size) in [12, 16, 24, 32].enumerated() {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular),
                    .foregroundColor: NSColor(white: 0.94, alpha: 1),
                ]
                let line = NSAttributedString(string: text, attributes: attributes)
                let graphics = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                line.draw(at: CGPoint(x: 320, y: 1_016 - index * 64))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private static func fill(
        _ bytes: inout [UInt8],
        width: Int,
        rect: CGRect,
        color: (UInt8, UInt8, UInt8)
    ) {
        let maxY = min(MediaBaselineLayout.canvasHeight, Int(rect.maxY))
        let maxX = min(width, Int(rect.maxX))
        for y in max(0, Int(rect.minY))..<maxY {
            for x in max(0, Int(rect.minX))..<maxX {
                setPixel(&bytes, width: width, x: x, y: y, color: color)
            }
        }
    }

    private static func setPixel(
        _ bytes: inout [UInt8],
        width: Int,
        x: Int,
        y: Int,
        color: (UInt8, UInt8, UInt8)
    ) {
        let offset = (y * width + x) * 4
        bytes[offset] = color.2
        bytes[offset + 1] = color.1
        bytes[offset + 2] = color.0
        bytes[offset + 3] = 255
    }
}
