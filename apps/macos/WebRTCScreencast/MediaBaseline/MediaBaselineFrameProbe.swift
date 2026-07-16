import AppKit
import CoreImage
import CoreVideo
import Foundation
@preconcurrency import WebRTC

enum MediaBaselineClock {
    static var nowNs: UInt64 {
        UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    }
}

enum MediaBaselineFrameStage: String, Sendable {
    case capture
    case decode
}

final class MediaBaselineFrameProbe: @unchecked Sendable {
    private let stage: MediaBaselineFrameStage
    private let recorder: MetricsRecorder
    private let directory: URL
    private let lock = NSLock()
    private var observedSequences: Set<UInt32> = []
    private var savedFirstFrame = false
    private let imageQueue = DispatchQueue(label: "cn.aweffr.WebRTCScreencast.media-baseline-images", qos: .utility)

    init(stage: MediaBaselineFrameStage, recorder: MetricsRecorder, directory: URL) {
        self.stage = stage
        self.recorder = recorder
        self.directory = directory
    }

    func observe(
        pixelBuffer: CVPixelBuffer,
        frameTimestampNs: Int64,
        callbackNs: UInt64 = MediaBaselineClock.nowNs
    ) {
        saveFirstFrameIfNeeded(pixelBuffer)
        let marker: MediaBaselineMarker
        do {
            marker = try MediaBaselinePixelProbe.detect(pixelBuffer: pixelBuffer, roi: MediaBaselineLayout.markerROI)
        } catch MediaBaselineMarkerError.checksumMismatch {
            recordInvalid(callbackNs: callbackNs)
            return
        } catch { return }
        guard claim(marker.sequence) else { return }
        record(sequence: marker.sequence, callbackNs: callbackNs, frameTimestampNs: frameTimestampNs)
        guard MediaBaselineLayout.qualitySampleSequences.contains(marker.sequence) else { return }
        guard let snapshot = Self.copyPixelBuffer(pixelBuffer) else { return }
        let retained = SendablePixelBuffer(value: snapshot)
        imageQueue.async { [stage, directory] in
            guard let data = Self.pngData(pixelBuffer: retained.value) else { return }
            let name = String(format: "%@-%06u.png", stage == .capture ? "sender-capture" : "receiver-decoded", marker.sequence)
            try? data.write(to: directory.appending(path: name), options: .atomic)
        }
    }

    func observe(frame: RTCVideoFrame) {
        if let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
            observe(pixelBuffer: cvBuffer.pixelBuffer, frameTimestampNs: frame.timeStampNs)
            return
        }
        let callbackNs = MediaBaselineClock.nowNs
        let i420 = frame.buffer.toI420()
        saveFirstI420FrameIfNeeded(i420)
        let marker: MediaBaselineMarker
        do {
            marker = try MediaBaselinePixelProbe.detect(i420: i420, roi: MediaBaselineLayout.markerROI)
        } catch MediaBaselineMarkerError.checksumMismatch {
            recordInvalid(callbackNs: callbackNs)
            return
        } catch { return }
        guard claim(marker.sequence) else { return }
        record(sequence: marker.sequence, callbackNs: callbackNs, frameTimestampNs: frame.timeStampNs)
        guard MediaBaselineLayout.qualitySampleSequences.contains(marker.sequence),
              let pixelBuffer = Self.pixelBuffer(i420: i420)
        else { return }
        enqueuePNG(
            pixelBuffer: pixelBuffer,
            name: String(format: "receiver-decoded-%06u.png", marker.sequence)
        )
    }

    private func claim(_ sequence: UInt32) -> Bool {
        lock.withLock { observedSequences.insert(sequence).inserted }
    }

    private func saveFirstFrameIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        let shouldSave = lock.withLock { () -> Bool in
            guard !savedFirstFrame else { return false }
            savedFirstFrame = true
            return true
        }
        guard shouldSave else { return }
        guard let snapshot = Self.copyPixelBuffer(pixelBuffer) else { return }
        let retained = SendablePixelBuffer(value: snapshot)
        imageQueue.async { [stage, directory] in
            guard let data = Self.pngData(pixelBuffer: retained.value) else { return }
            let name = stage == .capture ? "baseline-first-capture.png" : "baseline-first-decode.png"
            try? data.write(to: directory.appending(path: name), options: .atomic)
        }
    }

    private func saveFirstI420FrameIfNeeded(_ i420: any RTCI420BufferProtocol) {
        let shouldSave = lock.withLock { () -> Bool in
            guard !savedFirstFrame else { return false }
            savedFirstFrame = true
            return true
        }
        guard shouldSave, let pixelBuffer = Self.pixelBuffer(i420: i420) else { return }
        enqueuePNG(pixelBuffer: pixelBuffer, name: "baseline-first-decode.png")
    }

    private func enqueuePNG(pixelBuffer: CVPixelBuffer, name: String) {
        let retained = SendablePixelBuffer(value: pixelBuffer)
        imageQueue.async { [directory] in
            guard let data = Self.pngData(pixelBuffer: retained.value) else { return }
            try? data.write(to: directory.appending(path: name), options: .atomic)
        }
    }

    private func record(sequence: UInt32, callbackNs: UInt64, frameTimestampNs: Int64) {
        let event = stage == .capture ? "baseline_capture_detected" : "baseline_decode_detected"
        Task {
            try? await recorder.record(event: event, fields: [
                "sequence": .integer(Int(sequence)),
                "callback_monotonic_ns": .integer(Int(callbackNs)),
                "frame_timestamp_ns": .integer(Int(frameTimestampNs)),
            ])
        }
    }

    private func recordInvalid(callbackNs: UInt64) {
        Task {
            try? await recorder.record(event: "baseline_marker_invalid", fields: [
                "stage": .string(stage.rawValue),
                "reason": .string("checksum_mismatch"),
                "callback_monotonic_ns": .integer(Int(callbackNs)),
            ])
        }
    }

    private static func pngData(pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(source),
            CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source),
            nil,
            &destination
        ) == kCVReturnSuccess, let destination else { return nil }

        if let attachments = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(destination, attachments, .shouldPropagate)
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if CVPixelBufferIsPlanar(source) {
            guard CVPixelBufferGetPlaneCount(source) == CVPixelBufferGetPlaneCount(destination) else { return nil }
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
                else { return nil }
                let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let rowBytes = min(sourceStride, destinationStride)
                let height = CVPixelBufferGetHeightOfPlane(source, plane)
                for row in 0..<height {
                    destinationBase.advanced(by: row * destinationStride).copyMemory(
                        from: sourceBase.advanced(by: row * sourceStride),
                        byteCount: rowBytes
                    )
                }
            }
        } else {
            guard let sourceBase = CVPixelBufferGetBaseAddress(source),
                  let destinationBase = CVPixelBufferGetBaseAddress(destination)
            else { return nil }
            let sourceStride = CVPixelBufferGetBytesPerRow(source)
            let destinationStride = CVPixelBufferGetBytesPerRow(destination)
            let rowBytes = min(sourceStride, destinationStride)
            for row in 0..<CVPixelBufferGetHeight(source) {
                destinationBase.advanced(by: row * destinationStride).copyMemory(
                    from: sourceBase.advanced(by: row * sourceStride),
                    byteCount: rowBytes
                )
            }
        }
        return destination
    }

    private static func pixelBuffer(i420: any RTCI420BufferProtocol) -> CVPixelBuffer? {
        let width = Int(i420.width)
        let height = Int(i420.height)
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else { return nil }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for row in 0..<height {
            yBase.advanced(by: row * yStride).update(from: i420.dataY.advanced(by: row * Int(i420.strideY)), count: width)
        }
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for row in 0..<(height / 2) {
            let u = i420.dataU.advanced(by: row * Int(i420.strideU))
            let v = i420.dataV.advanced(by: row * Int(i420.strideV))
            let destination = uvBase.advanced(by: row * uvStride)
            for column in 0..<(width / 2) {
                destination[column * 2] = u[column]
                destination[column * 2 + 1] = v[column]
            }
        }
        return pixelBuffer
    }
}

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}
