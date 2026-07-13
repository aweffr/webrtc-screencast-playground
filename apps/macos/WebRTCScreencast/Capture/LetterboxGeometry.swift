import CoreGraphics

enum LetterboxGeometryError: Error {
    case invalidSize
}

enum LetterboxGeometry {
    static func destinationRect(source: CGSize, canvas: CGSize) throws -> CGRect {
        guard source.width > 0, source.height > 0, canvas.width > 0, canvas.height > 0 else {
            throw LetterboxGeometryError.invalidSize
        }
        let scale = min(canvas.width / source.width, canvas.height / source.height)
        let output = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: (canvas.width - output.width) / 2,
            y: (canvas.height - output.height) / 2,
            width: output.width,
            height: output.height
        )
    }
}
