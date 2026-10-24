import Foundation

/// The latest published release, as far as the updater needs to know it
/// (2026-10-24).
///
/// Read from GitHub's `releases/latest`, the endpoint `Scripts/install.sh`
/// asks, and cached in the preferences domain — a 304 has no body, so the
/// release an unchanged reply refers to has to be remembered from the last
/// 200. `Codable` for that cache only.
public struct Release: Codable, Equatable, Sendable {
    /// As tagged, "v0.13.0".
    public let tag: String
    /// The release page, opened by "Release Notes".
    public let notesURL: URL
    /// The `.tar.gz` the release workflow attaches, if it is there.
    public let archiveURL: URL?
    /// Its `.sha256`, if it is there.
    public let checksumURL: URL?

    public init(tag: String, notesURL: URL, archiveURL: URL?, checksumURL: URL?) {
        self.tag = tag
        self.notesURL = notesURL
        self.archiveURL = archiveURL
        self.checksumURL = checksumURL
    }

    /// `nil` for a tag that is not a version — which is then never newer.
    public var version: SemanticVersion? { SemanticVersion(tag) }

    /// The names `release.yml` gives the assets: `CreativeNotch-<tag>.tar.gz`
    /// and that plus `.sha256`.
    public var archiveName: String { Self.archiveName(for: tag) }
    public var checksumName: String { archiveName + ".sha256" }

    static func archiveName(for tag: String) -> String { "CreativeNotch-\(tag).tar.gz" }

    /// Both assets present. A release without its checksum can be announced
    /// — with its notes — but is never installed: nothing goes in unverified.
    public var isInstallable: Bool { archiveURL != nil && checksumURL != nil }

    /// The release in a `releases/latest` body, or `nil` if the body is not
    /// one.
    ///
    /// Only the asset named for this tag is taken — not the first `.tar.gz`,
    /// which is what `install.sh`'s `grep` settles for — so a stray source
    /// archive or a mislabelled upload is never what gets installed.
    ///
    /// Every link must be this repository's own, over HTTPS (2026-10-25):
    /// the notes a page under `github.com/GcdZ03/CreativeNotch/releases/`,
    /// and each asset exactly
    /// `github.com/GcdZ03/CreativeNotch/releases/download/<tag>/<name>`.
    /// These are URLs the app downloads from and hands to the browser, and
    /// the reply is the one input it does not control — the `.sha256` comes
    /// from the same reply as the archive, so the checksum cannot vouch for
    /// a link it was served beside. GitHub's redirect from there to its
    /// asset storage is followed by `URLSession` and is not this check's
    /// business. A link that fails is dropped: a foreign asset makes the
    /// release uninstallable, a foreign notes page makes the reply no
    /// release at all.
    public static func parse(_ data: Data) -> Release? {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              !reply.tagName.isEmpty,
              let notes = reply.htmlURL.flatMap(URL.init(string:)),
              isNotesPage(notes) else { return nil }
        func asset(named name: String) -> URL? {
            reply.assets?.first { $0.name == name }
                .flatMap { $0.downloadURL.flatMap(URL.init(string:)) }
                .flatMap { isAsset($0, named: name, tag: reply.tagName) ? $0 : nil }
        }
        let archive = archiveName(for: reply.tagName)
        return Release(
            tag: reply.tagName,
            notesURL: notes,
            archiveURL: asset(named: archive),
            checksumURL: asset(named: archive + ".sha256")
        )
    }

    /// Whether every link this release holds passes the checks `parse`
    /// makes. A release read back from the cache is held to it again, so a
    /// hand-edited preferences value cannot point "Update Now" elsewhere.
    public var isTrusted: Bool {
        Self.isNotesPage(notesURL)
            && archiveURL.map { Self.isAsset($0, named: archiveName, tag: tag) } != false
            && checksumURL.map { Self.isAsset($0, named: checksumName, tag: tag) } != false
    }

    /// A page of this repository's releases: `https://github.com/GcdZ03/
    /// CreativeNotch/releases/…`, at least one component below `releases`.
    static func isNotesPage(_ url: URL) -> Bool {
        guard let path = repositoryPath(url) else { return false }
        let prefix = ["releases"]
        return path.count > prefix.count && Array(path.prefix(prefix.count)) == prefix
    }

    /// Exactly `https://github.com/GcdZ03/CreativeNotch/releases/download/
    /// <tag>/<name>`, with no query or fragment.
    static func isAsset(_ url: URL, named name: String, tag: String) -> Bool {
        guard url.query == nil, url.fragment == nil,
              let path = repositoryPath(url) else { return false }
        return path == ["releases", "download", tag, name]
    }

    /// The path components after `/GcdZ03/CreativeNotch` for an HTTPS link
    /// to github.com itself — no other host, port or credentials — or `nil`.
    /// A "." or ".." component is refused outright: a server would resolve
    /// it, and resolved it could leave the repository.
    private static func repositoryPath(_ url: URL) -> [String]? {
        guard url.scheme?.lowercased() == "https",
              url.host()?.lowercased() == UpdateEndpoint.host,
              url.port == nil, url.user() == nil, url.password() == nil else { return nil }
        let components = url.pathComponents
        guard components.first == "/",
              !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let rest = Array(components.dropFirst())
        let repository = UpdateEndpoint.repository.split(separator: "/").map(String.init)
        guard rest.count > repository.count, Array(rest.prefix(repository.count)) == repository else { return nil }
        return Array(rest.dropFirst(repository.count))
    }

    /// The fields read from GitHub's reply; everything else is ignored.
    private struct Reply: Decodable {
        let tagName: String
        let htmlURL: String?
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let downloadURL: String?

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }
    }
}

/// Where the updater asks, and how it introduces itself.
public enum UpdateEndpoint {
    /// The repository every release link must belong to, as `install.sh`'s
    /// `REPO`.
    public static let repository = "GcdZ03/CreativeNotch"
    /// The only host a release link may name. Its downloads redirect to
    /// GitHub's asset storage; that hop is `URLSession`'s to follow.
    public static let host = "github.com"

    /// The endpoint `Scripts/install.sh` uses, so the app and the installer
    /// can never disagree about what "latest" means.
    public static let latestRelease = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// Who is asking, on every request the updater makes — the API call
    /// and both downloads.
    public static func userAgent(version: String) -> String {
        "CreativeNotch/\(version)"
    }

    /// The request's headers. GitHub refuses a request with no
    /// `User-Agent`; the `Accept` and API version pin the reply's shape.
    /// `If-None-Match` makes an unchanged release a 304, which GitHub does
    /// not count against the hourly limit for unauthenticated callers.
    public static func headers(version: String, etag: String?) -> [String: String] {
        var headers = [
            "User-Agent": userAgent(version: version),
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ]
        if let etag { headers["If-None-Match"] = etag }
        return headers
    }
}

/// An HTTP reply, reduced to what the classifier reads. Core never sees a
/// `URLResponse`.
public struct HTTPReply: Equatable, Sendable {
    public let status: Int
    public let body: Data
    public let etag: String?
    /// `X-RateLimit-Remaining`, as sent.
    public let rateLimitRemaining: String?

    public init(status: Int, body: Data, etag: String?, rateLimitRemaining: String?) {
        self.status = status
        self.body = body
        self.etag = etag
        self.rateLimitRemaining = rateLimitRemaining
    }
}

/// Why a check found nothing out. All three are quiet for a check nobody
/// asked for; only the menu's "Check for Updates…" reports them.
public enum UpdateCheckFailure: Equatable, Sendable {
    /// No reply at all: offline, DNS, a timeout.
    case offline
    /// GitHub's unauthenticated limit — a 403 with nothing remaining, or a 429.
    case rateLimited
    /// A reply that was not a release.
    case unexpected
}

/// What one check learned.
public enum UpdateCheckResult: Equatable, Sendable {
    case fresh(Release, etag: String?)
    case notModified
    case failed(UpdateCheckFailure)

    /// `nil` means the request never got a reply.
    public static func classify(_ reply: HTTPReply?) -> UpdateCheckResult {
        guard let reply else { return .failed(.offline) }
        switch reply.status {
        case 200:
            guard let release = Release.parse(reply.body) else { return .failed(.unexpected) }
            return .fresh(release, etag: reply.etag)
        case 304:
            return .notModified
        case 429:
            return .failed(.rateLimited)
        case 403 where reply.rateLimitRemaining == "0":
            return .failed(.rateLimited)
        default:
            return .failed(.unexpected)
        }
    }
}

/// The `.sha256` file the release workflow writes beside the archive.
public enum ReleaseChecksum {
    /// The digest in `shasum -a 256 NAME > NAME.sha256`'s output —
    /// "<64 hex>  NAME" — lowercased; `nil` if it names another file or the
    /// digest is not 64 hex digits. A bare digest, with no name, is
    /// accepted: there is nothing in it to disagree with.
    public static func expected(in text: String, for archiveName: String) -> String? {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard let digest = fields.first, digest.count == 64,
              digest.allSatisfy(\.isHexDigit) else { return nil }
        if fields.count > 1 {
            // `shasum -b` marks binary mode with a leading "*".
            var name = fields[1]
            if name.hasPrefix("*") { name = name.dropFirst() }
            guard name == archiveName else { return nil }
        }
        return digest.lowercased()
    }

    /// Whether a computed digest is the expected one.
    public static func matches(_ expected: String, digest: String) -> Bool {
        !expected.isEmpty && expected.lowercased() == digest.lowercased()
    }
}
