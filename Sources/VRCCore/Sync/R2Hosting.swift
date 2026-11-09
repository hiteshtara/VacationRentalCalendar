import Foundation
import CryptoKit

/// Everything needed to serve the filtered feeds from Cloudflare R2.
///
/// Note what is absent: no access key, no secret, no API token. Those are
/// credentials and live in the Keychain alongside the inbound feed URLs. This
/// type holds only the shape of the deployment, which is safe to store and to
/// show.
public struct R2HostingConfiguration: Sendable, Hashable {
    /// Cloudflare account identifier (not secret, but not useful alone).
    public var accountID: String
    public var bucket: String
    /// The domain attached to the bucket. Production requires a custom domain:
    /// the `r2.dev` subdomain is documented as development-only and has no
    /// caching, WAF or access controls.
    public var customDomain: String
    /// Cloudflare zone for cache purging.
    public var zoneID: String
    /// Path prefix inside the bucket.
    public var keyPrefix: String

    /// Keychain references for the three secrets.
    public var accessKeyRef: String
    public var secretKeyRef: String
    public var purgeTokenRef: String

    public init(
        accountID: String,
        bucket: String,
        customDomain: String,
        zoneID: String,
        keyPrefix: String = "feeds",
        accessKeyRef: String = "r2-access-key-id",
        secretKeyRef: String = "r2-secret-access-key",
        purgeTokenRef: String = "cloudflare-purge-token"
    ) {
        self.accountID = accountID
        self.bucket = bucket
        self.customDomain = customDomain
        self.zoneID = zoneID
        self.keyPrefix = keyPrefix
        self.accessKeyRef = accessKeyRef
        self.secretKeyRef = secretKeyRef
        self.purgeTokenRef = purgeTokenRef
    }

    /// The object key for one destination's feed.
    ///
    /// Security here is an unguessable path, exactly as Airbnb and Vrbo do for
    /// their own export URLs. R2 does not list bucket contents publicly and
    /// returns 404 for a wrong key, so a 128-bit token is not enumerable.
    /// Presigned URLs are deliberately not used: they only work on the S3 API
    /// endpoint, not a custom domain, and they expire — which is precisely
    /// wrong for a URL a platform must keep fetching indefinitely.
    public func key(propertySlug: String, destination: RentalPlatform, token: String) -> String {
        "\(keyPrefix)/\(propertySlug)/\(destination.rawValue)/\(token).ics"
    }

    public func publicURL(
        propertySlug: String, destination: RentalPlatform, token: String
    ) -> String {
        "https://\(customDomain)/\(key(propertySlug: propertySlug, destination: destination, token: token))"
    }

    /// Safe to print and to show in the interface.
    public func redactedURL(propertySlug: String, destination: RentalPlatform) -> String {
        "https://\(customDomain)/\(keyPrefix)/\(propertySlug)/\(destination.rawValue)/"
            + "<32-hex-token>.ics"
    }

    public var s3Endpoint: String { "https://\(accountID).r2.cloudflarestorage.com" }

    /// Sixty seconds, with revalidation. Short enough that reopening dates
    /// takes effect quickly, long enough that polling platforms are cheap.
    /// The dangerous direction is stale-when-reopening: a cached block that
    /// outlives its withdrawal keeps nights off sale.
    public static let cacheControl = "public, max-age=60, must-revalidate"
}

public struct R2Credentials: Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var purgeToken: String

    public init(accessKeyID: String, secretAccessKey: String, purgeToken: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.purgeToken = purgeToken
    }
}

/// Uploads feeds to R2 and purges Cloudflare's cache.
///
/// Implemented against R2's S3-compatible API with SigV4. **Nothing in this
/// build calls it**: `OutboundSyncCoordinator.publish` refuses while the gate
/// is shut, and no configuration is stored. It exists so the deployment can be
/// reviewed as code rather than as a plan.
public struct R2HostingClient: FeedHostingClient {
    let configuration: R2HostingConfiguration
    let credentials: R2Credentials
    let session: URLSession

    public init(
        configuration: R2HostingConfiguration,
        credentials: R2Credentials,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.session = session
    }

    /// A single PUT. Object storage replaces an object atomically: a reader
    /// sees the old bytes or the new ones, never a half-written file.
    public func upload(key: String, body: String, cacheControl: String) async throws {
        let payload = Data(body.utf8)
        guard let url = URL(string: "\(configuration.s3Endpoint)/\(configuration.bucket)/\(key)")
        else { throw HostingError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = payload
        request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(cacheControl, forHTTPHeaderField: "Cache-Control")

        try sign(&request, payload: payload, service: "s3")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
                throw HostingError.uploadFailed("HTTP \(status) \(detail)")
            }
        } catch let error as HostingError {
            throw error
        } catch {
            throw HostingError.uploadFailed(error.localizedDescription)
        }
    }

    /// Purging is not optional. On a custom domain R2 objects are served
    /// through Cloudflare's cache, so without it a platform can keep reading
    /// the previous feed — which matters most when reopening dates, because a
    /// stale block keeps nights off sale.
    public func invalidateCache(key: String) async throws {
        let target = "https://\(configuration.customDomain)/\(key)"
        guard let url = URL(
            string: "https://api.cloudflare.com/client/v4/zones/\(configuration.zoneID)/purge_cache"
        ) else { throw HostingError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.purgeToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["files": [target]])

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let succeeded = (body?["success"] as? Bool) ?? false
            guard (200...299).contains(status), succeeded else {
                throw HostingError.cacheInvalidationFailed(
                    "HTTP \(status) " + (String(data: data.prefix(300), encoding: .utf8) ?? "")
                )
            }
        } catch let error as HostingError {
            throw error
        } catch {
            throw HostingError.cacheInvalidationFailed(error.localizedDescription)
        }
    }

    // MARK: - AWS SigV4

    private func sign(_ request: inout URLRequest, payload: Data, service: String) throws {
        guard let url = request.url, let host = url.host else {
            throw HostingError.notConfigured
        }
        let now = Date()
        let amzDate = Self.amzFormatter.string(from: now)
        let dateStamp = String(amzDate.prefix(8))
        let region = "auto"
        let payloadHash = Self.hex(SHA256.hash(data: payload))

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Canonical request. Headers must be lowercase and sorted.
        var headers: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", amzDate),
        ]
        if let type = request.value(forHTTPHeaderField: "Content-Type") {
            headers.append(("content-type", type))
        }
        if let cache = request.value(forHTTPHeaderField: "Cache-Control") {
            headers.append(("cache-control", cache))
        }
        headers.sort { $0.0 < $1.0 }

        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers
            .map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))\n" }
            .joined()
        let canonicalRequest = [
            request.httpMethod ?? "PUT",
            url.path.isEmpty ? "/" : url.path,
            url.query ?? "",
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for component in [dateStamp, region, service, "aws4_request"] {
            let mac = HMAC<SHA256>.authenticationCode(
                for: Data(component.utf8), using: key
            )
            key = SymmetricKey(data: Data(mac))
        }
        let signature = Self.hex(
            HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        )

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    static let amzFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Writes feeds to a directory instead of the internet.
///
/// Used to rehearse the whole publication pipeline — safety assessment,
/// upload, cache purge, snapshot, rollback — without an account, a domain or a
/// network. The "cache" is a second directory, so a failed purge is a state the
/// rehearsal can actually produce rather than merely assert.
public actor LocalDirectoryHostingClient: FeedHostingClient {
    public let originDirectory: URL
    public let cacheDirectory: URL
    public var failUpload: String?
    public var failInvalidation: String?
    public private(set) var uploadCount = 0
    public private(set) var purgeCount = 0

    public init(root: URL) throws {
        originDirectory = root.appendingPathComponent("origin", isDirectory: true)
        cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: originDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )
    }

    public func setFailUpload(_ value: String?) { failUpload = value }
    public func setFailInvalidation(_ value: String?) { failInvalidation = value }

    private func path(_ base: URL, _ key: String) -> URL {
        base.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"))
    }

    public func upload(key: String, body: String, cacheControl: String) async throws {
        if let failUpload { throw HostingError.uploadFailed(failUpload) }
        // Written to a temporary name and moved, which is how an atomic
        // replacement behaves: a reader sees old bytes or new, never partial.
        let destination = path(originDirectory, key)
        let temporary = destination.appendingPathExtension("partial")
        try Data(body.utf8).write(to: temporary, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        uploadCount += 1
    }

    public func invalidateCache(key: String) async throws {
        if let failInvalidation {
            throw HostingError.cacheInvalidationFailed(failInvalidation)
        }
        // Copying origin to cache models the purge: until it happens, readers
        // keep being served whatever the cache already holds.
        let origin = path(originDirectory, key)
        let cached = path(cacheDirectory, key)
        if FileManager.default.fileExists(atPath: origin.path) {
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.copyItem(at: origin, to: cached)
        }
        purgeCount += 1
    }

    /// What a platform polling the URL right now would actually receive.
    public func servedBody(key: String) -> String? {
        try? String(contentsOf: path(cacheDirectory, key), encoding: .utf8)
    }

    public func originBody(key: String) -> String? {
        try? String(contentsOf: path(originDirectory, key), encoding: .utf8)
    }
}
