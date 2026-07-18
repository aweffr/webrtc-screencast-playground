import CoreGraphics
import CoreVideo
import Foundation
@preconcurrency import WebRTC

enum MediaBaselinePixelProbeError: Error, Equatable {
    case unsupportedPixelFormat(OSType)
    case missingBaseAddress
    case invalidROI
}

enum MediaBaselinePixelProbe {
    static func detect(
        pixelBuffer: CVPixelBuffer,
        candidateROIs: [CGRect]
    ) throws -> MediaBaselineMarker {
        var lastError: (any Error)?
        for roi in candidateROIs {
            do { return try detect(pixelBuffer: pixelBuffer, roi: roi) }
            catch { lastError = error }
        }
        throw lastError ?? MediaBaselinePixelProbeError.invalidROI
    }

    static func detect(pixelBuffer: CVPixelBuffer, roi: CGRect) throws -> MediaBaselineMarker {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if CVPixelBufferIsPlanar(pixelBuffer) {
            guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
                  let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            else { throw MediaBaselinePixelProbeError.missingBaseAddress }
            return try detect(
                luma: base.assumingMemoryBound(to: UInt8.self),
                width: width,
                height: height,
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                roi: roi
            )
        }
        guard format == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer)
        else { throw MediaBaselinePixelProbeError.unsupportedPixelFormat(format) }
        return try detectBGRA(
            base: base.assumingMemoryBound(to: UInt8.self),
            width: width,
            height: height,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            roi: roi
        )
    }

    static func detect(i420: any RTCI420BufferProtocol, roi: CGRect) throws -> MediaBaselineMarker {
        try detect(
            luma: i420.dataY,
            width: Int(i420.width),
            height: Int(i420.height),
            bytesPerRow: Int(i420.strideY),
            roi: roi
        )
    }

    static func detect(
        i420: any RTCI420BufferProtocol,
        candidateROIs: [CGRect]
    ) throws -> MediaBaselineMarker {
        var lastError: (any Error)?
        for roi in candidateROIs {
            do { return try detect(i420: i420, roi: roi) }
            catch { lastError = error }
        }
        throw lastError ?? MediaBaselinePixelProbeError.invalidROI
    }

    private static func detect(
        luma: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        roi: CGRect
    ) throws -> MediaBaselineMarker {
        let bounds = try integerBounds(roi: roi, width: width, height: height)
        var bytes = [UInt8](repeating: 0, count: bounds.width * bounds.height)
        for row in 0..<bounds.height {
            bytes.withUnsafeMutableBytes { destination in
                destination.baseAddress!.advanced(by: row * bounds.width).copyMemory(
                    from: luma.advanced(by: (bounds.minY + row) * bytesPerRow + bounds.minX),
                    byteCount: bounds.width
                )
            }
        }
        return try MediaBaselineMarker.decode(
            luma: bytes,
            width: bounds.width,
            height: bounds.height,
            bytesPerRow: bounds.width,
            roi: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        )
    }

    private static func detectBGRA(
        base: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        roi: CGRect
    ) throws -> MediaBaselineMarker {
        let bounds = try integerBounds(roi: roi, width: width, height: height)
        var luma = [UInt8](repeating: 0, count: bounds.width * bounds.height)
        for row in 0..<bounds.height {
            for column in 0..<bounds.width {
                let pixel = base.advanced(by: (bounds.minY + row) * bytesPerRow + (bounds.minX + column) * 4)
                let blue = 29 * Int(pixel[0])
                let green = 150 * Int(pixel[1])
                let red = 77 * Int(pixel[2])
                luma[row * bounds.width + column] = UInt8((blue + green + red) >> 8)
            }
        }
        return try MediaBaselineMarker.decode(
            luma: luma,
            width: bounds.width,
            height: bounds.height,
            bytesPerRow: bounds.width,
            roi: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        )
    }

    private static func integerBounds(roi: CGRect, width: Int, height: Int) throws -> (minX: Int, minY: Int, width: Int, height: Int) {
        let minX = Int(roi.minX.rounded())
        let minY = Int(roi.minY.rounded())
        let roiWidth = Int(roi.width.rounded())
        let roiHeight = Int(roi.height.rounded())
        guard minX >= 0, minY >= 0, roiWidth > 0, roiHeight > 0,
              minX + roiWidth <= width, minY + roiHeight <= height
        else { throw MediaBaselinePixelProbeError.invalidROI }
        return (minX, minY, roiWidth, roiHeight)
    }
}
