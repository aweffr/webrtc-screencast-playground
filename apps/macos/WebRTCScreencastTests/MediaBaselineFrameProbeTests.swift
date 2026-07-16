import CoreVideo
import XCTest
@testable import WebRTCScreencast

final class MediaBaselineFrameProbeTests: XCTestCase {
    func testPixelBufferCopyDoesNotObserveLaterSourceReuse() throws {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &created
        ), kCVReturnSuccess)
        let source = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(source, [])
        CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)[0] = 17
        CVPixelBufferUnlockBaseAddress(source, [])
        CVBufferSetAttachment(
            source,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )

        let snapshot = try XCTUnwrap(MediaBaselineFrameProbe.copyPixelBuffer(source))
        CVPixelBufferLockBaseAddress(source, [])
        CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)[0] = 99
        CVPixelBufferUnlockBaseAddress(source, [])

        CVPixelBufferLockBaseAddress(snapshot, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(snapshot, .readOnly) }
        XCTAssertEqual(CVPixelBufferGetBaseAddress(snapshot)!.assumingMemoryBound(to: UInt8.self)[0], 17)
        XCTAssertEqual(
            CVBufferCopyAttachment(snapshot, kCVImageBufferYCbCrMatrixKey, nil) as? String,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        )
    }
}
