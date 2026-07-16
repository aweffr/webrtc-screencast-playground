import CoreGraphics
import CoreVideo
import XCTest
@testable import WebRTCScreencast

final class MediaBaselineMarkerTests: XCTestCase {
    func testBinaryGridRoundTripsSequenceFromLumaPlane() throws {
        let marker = MediaBaselineMarker(sequence: 0x1020_3040)
        let image = marker.makeLumaImage(cellSize: 8)

        let decoded = try MediaBaselineMarker.decode(
            luma: image.bytes,
            width: image.width,
            height: image.height,
            bytesPerRow: image.bytesPerRow,
            roi: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )

        XCTAssertEqual(decoded.sequence, marker.sequence)
    }

    func testBinaryGridRejectsCorruptedPayload() throws {
        let marker = MediaBaselineMarker(sequence: 42)
        var image = marker.makeLumaImage(cellSize: 8)
        let payloadCell = MediaBaselineMarker.payloadCells[7]
        let x = payloadCell.x * 8 + 4
        let y = payloadCell.y * 8 + 4
        image.bytes[y * image.bytesPerRow + x] ^= 0xff

        XCTAssertThrowsError(try MediaBaselineMarker.decode(
            luma: image.bytes,
            width: image.width,
            height: image.height,
            bytesPerRow: image.bytesPerRow,
            roi: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )) { error in
            XCTAssertEqual(error as? MediaBaselineMarkerError, .checksumMismatch)
        }
    }

    func testPixelProbeDecodesMarkerFromNV12CaptureBuffer() throws {
        let markerImage = MediaBaselineMarker(sequence: 99).makeLumaImage(cellSize: 8)
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            nil,
            markerImage.width,
            markerImage.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<markerImage.height {
            yBase.advanced(by: row * yStride).copyMemory(
                from: markerImage.bytes.withUnsafeBytes { $0.baseAddress!.advanced(by: row * markerImage.bytesPerRow) },
                byteCount: markerImage.width
            )
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let decoded = try MediaBaselinePixelProbe.detect(
            pixelBuffer: buffer,
            roi: CGRect(x: 0, y: 0, width: markerImage.width, height: markerImage.height)
        )

        XCTAssertEqual(decoded.sequence, 99)
    }
}
