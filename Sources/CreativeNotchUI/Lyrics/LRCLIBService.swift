import Foundation
import CreativeNotchCore

/// The real lyrics request (spec 2026-10-29, "The service").
///
/// An ephemeral session: no cookie jar, no URL cache on disk, so nothing
/// about what was played is written anywhere by the request either. The
/// `User-Agent` names the app and its version, as LRCLIB asks of clients --
/// the updater's, so the app introduces itself one way everywhere.
/// Never logs the URL -- it carries the title and the artist.
enum LRCLIBService {

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static let userAgent = UpdateEndpoint.userAgent(version: CoreInfo.version)

    @Sendable
    static func fetch(_ url: URL) async -> (status: Int, body: Data)? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (body, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        return (http.statusCode, body)
    }
}
