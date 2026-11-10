import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
// swift-crypto provides the same API surface under a different module name.
// SHA256, HMAC and SymmetricKey are source-compatible, so nothing below
// changes shape -- which matters, because an AWS SigV4 signature that differs
// by a byte is simply rejected, and the iCal event keys are persisted.
import Crypto
#endif

/// AWS SigV4, shared by the R2 and S3 clients — R2's API is S3-compatible, so
/// the signing is identical apart from the region and service names.
public struct SigV4Signer: Sendable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let region: String
    public let service: String

    public init(accessKeyID: String, secretAccessKey: String, region: String, service: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.region = region
        self.service = service
    }

    /// Signs `request` in place.
    ///
    /// `alsoSign` names extra headers to bring inside the signature. The
    /// default set is deliberately small: every signed header must be present
    /// on the wire exactly as it was at signing time, and URLSession adds some
    /// of its own (User-Agent, Accept-Encoding) after we are done — so signing
    /// everything present would produce intermittent signature mismatches.
    /// Headers that carry meaning, such as an idempotency key, are opted in by
    /// the caller so they cannot be altered in transit.
    public func sign(
        _ request: inout URLRequest,
        payload: Data,
        now: Date = Date(),
        alsoSign: [String] = []
    ) throws {
        guard let url = request.url, let host = url.host else {
            throw HostingError.notConfigured
        }
        let amzDate = Self.amzFormatter.string(from: now)
        let dateStamp = String(amzDate.prefix(8))
        let payloadHash = Self.hex(SHA256.hash(data: payload))

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        var headers: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", amzDate),
        ]
        for name in ["Content-Type", "Cache-Control"] + alsoSign {
            if let value = request.value(forHTTPHeaderField: name) {
                headers.append((name.lowercased(), value))
            }
        }
        headers.sort { $0.0 < $1.0 }

        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers
            .map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))\n" }.joined()
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
            "AWS4-HMAC-SHA256", amzDate, scope,
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        for component in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(
                HMAC<SHA256>.authenticationCode(for: Data(component.utf8), using: key)
            ))
        }
        let signature = Self.hex(
            HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        )
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), "
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

/// Serving the feed from S3 behind CloudFront.
///
/// Recommended over R2 for this owner, for one reason that has nothing to do
/// with either product's merits: bostonfurnishedstays.com already runs on
/// Route 53 and CloudFront. R2 custom domains need the zone inside Cloudflare,
/// and partial (CNAME) setup is Business-plan only — so R2 would mean moving
/// the whole domain's nameservers away from Route 53, putting a live rental
/// website at risk to host one small file. This path adds a subdomain and
/// changes nothing that already works.
public struct AWSHostingConfiguration: Sendable, Hashable {
    public var bucket: String
    public var region: String
    /// CloudFront distribution serving the subdomain, used for invalidation.
    public var distributionID: String
    public var customDomain: String
    public var keyPrefix: String

    public var accessKeyRef: String
    public var secretKeyRef: String

    public init(
        bucket: String,
        region: String = "us-east-1",
        distributionID: String,
        customDomain: String,
        keyPrefix: String = "feeds",
        accessKeyRef: String = "aws-feed-access-key-id",
        secretKeyRef: String = "aws-feed-secret-access-key"
    ) {
        self.bucket = bucket
        self.region = region
        self.distributionID = distributionID
        self.customDomain = customDomain
        self.keyPrefix = keyPrefix
        self.accessKeyRef = accessKeyRef
        self.secretKeyRef = secretKeyRef
    }

    public func key(propertySlug: String, destination: RentalPlatform, token: String) -> String {
        "\(keyPrefix)/\(propertySlug)/\(destination.rawValue)/\(token).ics"
    }

    public func publicURL(
        propertySlug: String, destination: RentalPlatform, token: String
    ) -> String {
        "https://\(customDomain)/\(key(propertySlug: propertySlug, destination: destination, token: token))"
    }

    public func redactedURL(propertySlug: String, destination: RentalPlatform) -> String {
        "https://\(customDomain)/\(keyPrefix)/\(propertySlug)/\(destination.rawValue)/"
            + "<32-hex-token>.ics"
    }

    public static let cacheControl = "public, max-age=60, must-revalidate"
}

/// Uploads to S3 and invalidates CloudFront. Never called in this build.
public struct AWSHostingClient: FeedHostingClient {
    let configuration: AWSHostingConfiguration
    let signer: SigV4Signer
    let cloudFrontSigner: SigV4Signer
    let session: URLSession

    public init(
        configuration: AWSHostingConfiguration,
        accessKeyID: String,
        secretAccessKey: String,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.signer = SigV4Signer(
            accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            region: configuration.region, service: "s3"
        )
        // CloudFront is a global service and always signs against us-east-1.
        self.cloudFrontSigner = SigV4Signer(
            accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            region: "us-east-1", service: "cloudfront"
        )
        self.session = session
    }

    public func upload(key: String, body: String, cacheControl: String) async throws {
        let payload = Data(body.utf8)
        guard let url = URL(
            string: "https://\(configuration.bucket).s3.\(configuration.region).amazonaws.com/\(key)"
        ) else { throw HostingError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = payload
        request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(cacheControl, forHTTPHeaderField: "Cache-Control")
        try signer.sign(&request, payload: payload)

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                throw HostingError.uploadFailed(
                    "HTTP \(status) " + (String(data: data.prefix(300), encoding: .utf8) ?? "")
                )
            }
        } catch let error as HostingError {
            throw error
        } catch {
            throw HostingError.uploadFailed(error.localizedDescription)
        }
    }

    /// CloudFront caches at the edge, so without this a platform can keep
    /// reading the previous feed. The first 1,000 invalidation paths each
    /// month are free, and this uses one per publish.
    public func invalidateCache(key: String) async throws {
        guard let url = URL(
            string: "https://cloudfront.amazonaws.com/2020-05-31/distribution/"
                + "\(configuration.distributionID)/invalidation"
        ) else { throw HostingError.notConfigured }

        let reference = "vrc-\(Int(Date().timeIntervalSince1970))"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <InvalidationBatch xmlns="http://cloudfront.amazonaws.com/doc/2020-05-31/">
          <Paths><Quantity>1</Quantity><Items><Path>/\(key)</Path></Items></Paths>
          <CallerReference>\(reference)</CallerReference>
        </InvalidationBatch>
        """
        let payload = Data(xml.utf8)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        try cloudFrontSigner.sign(&request, payload: payload)

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
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
}
