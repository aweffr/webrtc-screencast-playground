enum CastingRole: String, Codable, CaseIterable, Sendable {
    case sender
    case receiver
}

enum CaptureSourceKind: String, Codable, CaseIterable, Sendable {
    case mainDisplayMirror = "main-display-mirror"
    case virtualExtendedDisplay = "virtual-extended-display"

    var enablesStaticClarity: Bool {
        switch self {
        case .mainDisplayMirror, .virtualExtendedDisplay:
            true
        }
    }
}
