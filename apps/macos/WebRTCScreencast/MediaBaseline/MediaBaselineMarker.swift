import CoreGraphics
import Foundation

enum MediaBaselineMarkerError: Error, Equatable {
    case invalidDimensions
    case finderMismatch
    case checksumMismatch
    case unsupportedVersion(UInt8)
}

struct MediaBaselineLumaImage: Equatable, Sendable {
    var bytes: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

struct MediaBaselineMarker: Equatable, Sendable {
    static let gridSize = 12
    static let version: UInt8 = 1
    static let payloadCells: [(x: Int, y: Int)] = (1..<(gridSize - 1)).flatMap { y in
        (1..<(gridSize - 1)).map { x in (x: x, y: y) }
    }

    let sequence: UInt32

    func makeLumaImage(cellSize: Int) -> MediaBaselineLumaImage {
        precondition(cellSize > 0)
        let cells = encodedCells()
        let size = Self.gridSize * cellSize
        var bytes = [UInt8](repeating: 255, count: size * size)
        for y in 0..<Self.gridSize {
            for x in 0..<Self.gridSize {
                let value: UInt8 = cells[y * Self.gridSize + x] ? 0 : 255
                for row in (y * cellSize)..<((y + 1) * cellSize) {
                    bytes.replaceSubrange(
                        (row * size + x * cellSize)..<(row * size + (x + 1) * cellSize),
                        with: repeatElement(value, count: cellSize)
                    )
                }
            }
        }
        return MediaBaselineLumaImage(bytes: bytes, width: size, height: size, bytesPerRow: size)
    }

    static func decode(
        luma: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        roi: CGRect
    ) throws -> MediaBaselineMarker {
        guard width > 0, height > 0, bytesPerRow >= width,
              luma.count >= bytesPerRow * height,
              roi.minX >= 0, roi.minY >= 0,
              roi.maxX <= CGFloat(width), roi.maxY <= CGFloat(height),
              roi.width >= CGFloat(gridSize), roi.height >= CGFloat(gridSize)
        else { throw MediaBaselineMarkerError.invalidDimensions }

        var cells = [Bool](repeating: false, count: gridSize * gridSize)
        for y in 0..<gridSize {
            for x in 0..<gridSize {
                let sampleX = min(width - 1, Int(roi.minX + (CGFloat(x) + 0.5) * roi.width / CGFloat(gridSize)))
                let sampleY = min(height - 1, Int(roi.minY + (CGFloat(y) + 0.5) * roi.height / CGFloat(gridSize)))
                cells[y * gridSize + x] = luma[sampleY * bytesPerRow + sampleX] < 128
            }
        }
        guard finderMatches(cells) else { throw MediaBaselineMarkerError.finderMismatch }

        let bits = payloadCells.map { cells[$0.y * gridSize + $0.x] }
        let bytes = bytes(from: bits, count: 7)
        let payload = Array(bytes.prefix(5))
        let expectedCRC = UInt16(bytes[5]) << 8 | UInt16(bytes[6])
        guard crc16(payload) == expectedCRC else { throw MediaBaselineMarkerError.checksumMismatch }
        guard payload[0] == version else { throw MediaBaselineMarkerError.unsupportedVersion(payload[0]) }
        let sequence = payload.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return MediaBaselineMarker(sequence: sequence)
    }

    private func encodedCells() -> [Bool] {
        var cells = [Bool](repeating: false, count: Self.gridSize * Self.gridSize)
        for y in 0..<Self.gridSize {
            for x in 0..<Self.gridSize where x == 0 || y == 0 || x == Self.gridSize - 1 || y == Self.gridSize - 1 {
                cells[y * Self.gridSize + x] = Self.finderValue(x: x, y: y)
            }
        }
        let payload: [UInt8] = [
            Self.version,
            UInt8(truncatingIfNeeded: sequence >> 24),
            UInt8(truncatingIfNeeded: sequence >> 16),
            UInt8(truncatingIfNeeded: sequence >> 8),
            UInt8(truncatingIfNeeded: sequence),
        ]
        let crc = Self.crc16(payload)
        let encoded = payload + [UInt8(crc >> 8), UInt8(truncatingIfNeeded: crc)]
        let bits = encoded.reduce(into: [Bool]()) { result, byte in
            result.append(contentsOf: (0..<8).map { bit in byte & (1 << (7 - bit)) != 0 })
        }
        for (cell, value) in zip(Self.payloadCells, bits) {
            cells[cell.y * Self.gridSize + cell.x] = value
        }
        return cells
    }

    private static func finderMatches(_ cells: [Bool]) -> Bool {
        for y in 0..<gridSize {
            for x in 0..<gridSize where x == 0 || y == 0 || x == gridSize - 1 || y == gridSize - 1 {
                if cells[y * gridSize + x] != finderValue(x: x, y: y) { return false }
            }
        }
        return true
    }

    private static func finderValue(x: Int, y: Int) -> Bool {
        if y == 0 { return x % 2 == 0 }
        if x == gridSize - 1 { return y % 2 == 0 }
        if y == gridSize - 1 { return x % 2 != 0 }
        return y % 2 != 0
    }

    private static func bytes(from bits: [Bool], count: Int) -> [UInt8] {
        (0..<count).map { byteIndex in
            (0..<8).reduce(UInt8(0)) { value, bitIndex in
                value | (bits[byteIndex * 8 + bitIndex] ? (1 << (7 - bitIndex)) : 0)
            }
        }
    }

    private static func crc16(_ bytes: [UInt8]) -> UInt16 {
        bytes.reduce(UInt16(0xffff)) { partial, byte in
            var crc = partial ^ (UInt16(byte) << 8)
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
            return crc
        }
    }
}
