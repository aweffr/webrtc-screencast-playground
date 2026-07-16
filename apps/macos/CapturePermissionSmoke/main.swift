import Darwin
import Foundation
import ScreenCaptureKit

@main
struct CapturePermissionSmoke {
    static func main() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            print("screen-capture-permission-smoke: displays=\(content.displays.count) windows=\(content.windows.count)")
            exit(content.displays.isEmpty ? 2 : 0)
        } catch {
            fputs("screen-capture-permission-smoke: \(error)\n", stderr)
            exit(1)
        }
    }
}
