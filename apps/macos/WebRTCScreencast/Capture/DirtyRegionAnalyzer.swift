import CoreGraphics

enum DirtyRegionAnalyzer {
    static func unionArea(of rects: [CGRect], clippedTo bounds: CGRect) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 0 }
        let clipped = rects.compactMap { rect -> CGRect? in
            let intersection = rect.standardized.intersection(bounds.standardized)
            return intersection.isNull || intersection.width <= 0 || intersection.height <= 0 ? nil : intersection
        }
        guard !clipped.isEmpty else { return 0 }

        let xCoordinates = Array(Set(clipped.flatMap { [$0.minX, $0.maxX] })).sorted()
        var area: CGFloat = 0
        for index in 0..<(xCoordinates.count - 1) {
            let minX = xCoordinates[index]
            let maxX = xCoordinates[index + 1]
            guard maxX > minX else { continue }
            var intervals: [(min: CGFloat, max: CGFloat)] = []
            for rect in clipped where rect.minX < maxX && rect.maxX > minX {
                intervals.append((min: rect.minY, max: rect.maxY))
            }
            intervals.sort { lhs, rhs in
                lhs.min == rhs.min ? lhs.max < rhs.max : lhs.min < rhs.min
            }
            guard var current = intervals.first else { continue }
            var coveredHeight: CGFloat = 0
            for interval in intervals.dropFirst() {
                if interval.min <= current.max {
                    current.max = max(current.max, interval.max)
                } else {
                    coveredHeight += current.max - current.min
                    current = interval
                }
            }
            coveredHeight += current.max - current.min
            area += (maxX - minX) * coveredHeight
        }
        return area
    }

    static func dirtyRatio(of rects: [CGRect], frameSize: CGSize) -> Double {
        guard frameSize.width > 0, frameSize.height > 0 else { return 0 }
        let bounds = CGRect(origin: .zero, size: frameSize)
        return Double(unionArea(of: rects, clippedTo: bounds) / (frameSize.width * frameSize.height))
    }
}
