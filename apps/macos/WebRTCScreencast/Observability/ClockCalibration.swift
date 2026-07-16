import Foundation

enum ClockCalibrationError: Error, Equatable {
    case noSamples
    case invalidSample
    case arithmeticOverflow
    case invalidSignalingURL
    case invalidResponse
}

struct ClockCalibration: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        let startedMonotonicNs: Int64
        let finishedMonotonicNs: Int64
        let serverUnixNs: Int64
    }

    let offsetNs: Int64
    let roundTripNs: Int64
    let uncertaintyNs: Int64
    let sampleCount: Int

    static func choose(_ samples: [Sample]) throws -> ClockCalibration {
        guard !samples.isEmpty else { throw ClockCalibrationError.noSamples }
        var selected: (offset: Int64, roundTrip: Int64)?
        for sample in samples {
            let (roundTrip, roundTripOverflow) = sample.finishedMonotonicNs
                .subtractingReportingOverflow(sample.startedMonotonicNs)
            guard !roundTripOverflow, roundTrip > 0 else {
                throw ClockCalibrationError.invalidSample
            }
            let (midpoint, midpointOverflow) = sample.startedMonotonicNs
                .addingReportingOverflow(roundTrip / 2)
            let (offset, offsetOverflow) = sample.serverUnixNs
                .subtractingReportingOverflow(midpoint)
            guard !midpointOverflow, !offsetOverflow else {
                throw ClockCalibrationError.arithmeticOverflow
            }
            if let current = selected {
                if roundTrip < current.roundTrip {
                    selected = (offset, roundTrip)
                }
            } else {
                selected = (offset, roundTrip)
            }
        }
        guard let selected else { throw ClockCalibrationError.noSamples }
        return ClockCalibration(
            offsetNs: selected.offset,
            roundTripNs: selected.roundTrip,
            uncertaintyNs: selected.roundTrip / 2,
            sampleCount: samples.count
        )
    }

    func commonTimeNs(monotonicNs: Int64) throws -> Int64 {
        let (result, overflow) = monotonicNs.addingReportingOverflow(offsetNs)
        guard !overflow else { throw ClockCalibrationError.arithmeticOverflow }
        return result
    }
}

struct ClockCalibrationClient: Sendable {
    private struct Response: Decodable {
        let schemaVersion: Int
        let serverUnixNs: Int64

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case serverUnixNs = "server_unix_ns"
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func endpoint(for signalingURL: URL) throws -> URL {
        guard var components = URLComponents(url: signalingURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased()
        else { throw ClockCalibrationError.invalidSignalingURL }
        switch scheme {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        default: throw ClockCalibrationError.invalidSignalingURL
        }
        components.user = nil
        components.password = nil
        components.path = "/clock"
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else {
            throw ClockCalibrationError.invalidSignalingURL
        }
        return endpoint
    }

    func calibrate(signalingURL: URL, sampleCount: Int = 5) async throws -> ClockCalibration {
        guard sampleCount > 0 else { throw ClockCalibrationError.noSamples }
        let endpoint = try Self.endpoint(for: signalingURL)
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 2
        var samples: [ClockCalibration.Sample] = []
        samples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            let started = try Self.monotonicNowNs()
            let (data, response) = try await session.data(for: request)
            let finished = try Self.monotonicNowNs()
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  response.value(forHTTPHeaderField: "Cache-Control") == "no-store"
            else { throw ClockCalibrationError.invalidResponse }
            let payload = try JSONDecoder().decode(Response.self, from: data)
            guard payload.schemaVersion == 1 else {
                throw ClockCalibrationError.invalidResponse
            }
            samples.append(.init(
                startedMonotonicNs: started,
                finishedMonotonicNs: finished,
                serverUnixNs: payload.serverUnixNs
            ))
        }
        return try ClockCalibration.choose(samples)
    }

    private static func monotonicNowNs() throws -> Int64 {
        let uptime = DispatchTime.now().uptimeNanoseconds
        guard uptime <= UInt64(Int64.max) else {
            throw ClockCalibrationError.arithmeticOverflow
        }
        return Int64(uptime)
    }
}
