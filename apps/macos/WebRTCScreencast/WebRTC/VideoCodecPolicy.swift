enum VideoCodecPolicy: String, CaseIterable, Codable, Sendable {
    case h264Only = "h264-only"
    case h265Only = "h265-only"
    case preferH265 = "prefer-h265"
    case `default` = "default"

    var orderedCodecNames: [String] {
        switch self {
        case .h264Only: ["H264"]
        case .h265Only: ["H265"]
        case .preferH265: ["H265", "H264"]
        case .default: ["H264", "H265"]
        }
    }
}
