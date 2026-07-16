import Darwin
import Foundation

@main
enum ExecutableMain {
    @MainActor
    static func main() {
        let arguments = ProcessInfo.processInfo.arguments
        if MediaBaselineChartHostOptions.isRequested(arguments) {
            do {
                try MediaBaselineChartHost.run(
                    options: MediaBaselineChartHostOptions.parse(arguments)
                )
            } catch {
                let message = "media baseline chart host failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(EXIT_FAILURE)
            }
        }
        WebRTCScreencastApp.main()
    }
}
