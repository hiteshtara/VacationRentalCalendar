import Foundation
import VRCCore
import VRCLambda

/// The public, read-only calendar endpoint.
///
/// This is a **separate handler from `vrc-lambda-publish` on purpose.** The
/// publish handler can write to S3 and invalidate a CDN; this one is the only
/// thing in the system reachable without AWS credentials, so it is given the
/// smallest possible job — look up a token, read one object, return it — and an
/// IAM role that can do nothing else. Sharing a handler would mean the public
/// surface inherited write permissions it has no use for.
///
/// Every decision about whether to answer lives in `FeedEndpoint`, which is a
/// pure function and unit-tested. This file is the plumbing around it.
///
/// What it deliberately never does: generate a calendar, touch the database,
/// publish anything, or report why a request failed. A caller learns only
/// "here is a calendar", "not found", or "method not allowed".

let environment = ProcessInfo.processInfo.environment

/// Server-side only. CloudWatch is private and this never reaches the caller,
/// who sees nothing but a status code. Tokens and secret values are never
/// passed here — only the category of failure, which is what diagnosing a
/// silent 404 actually requires.
func note(_ message: String) {
    FileHandle.standardError.write(Data(("vrc-feed: " + message + "\n").utf8))
}

func response(_ status: Int, body: String = "", headers: [String: String] = [:]) -> Data {
    LambdaJSON.data([
        "statusCode": status,
        "headers": headers.isEmpty ? ["content-type": "text/plain; charset=utf-8"] : headers,
        "body": body,
        "isBase64Encoded": false,
    ])
}

LambdaRuntime.run { invocation in
    let event = LambdaJSON.object(invocation.payload)
    let requestContext = event["requestContext"] as? [String: Any] ?? [:]
    let http = requestContext["http"] as? [String: Any] ?? [:]
    let method = http["method"] as? String ?? "GET"
    // `rawPath` is what a Lambda Function URL supplies; `path` is the API
    // Gateway spelling. Accepting both keeps this testable against either.
    let path = (event["rawPath"] as? String) ?? (http["path"] as? String) ?? "/"

    guard let key = environment["AWS_ACCESS_KEY_ID"],
          let secret = environment["AWS_SECRET_ACCESS_KEY"] else {
        // Misconfiguration, not a client error. Say nothing useful outward.
        return response(404, body: "Not found")
    }
    let region = environment["AWS_REGION"] ?? "us-east-1"
    let sessionToken = environment["AWS_SESSION_TOKEN"]

    // The grant table: sha256(token) -> object key. Read every invocation so a
    // revocation takes effect at once rather than at the next cold start.
    let grants: [String: FeedEndpoint.Grant]
    do {
        let reader = SecretsManagerReader(
            region: region, accessKeyID: key, secretAccessKey: secret,
            sessionToken: sessionToken)
        grants = FeedEndpoint.grants(
            from: try reader.secret(id: try ServiceContext(actor: "feed")
                .value("VRC_FEED_TOKENS_SECRET")))
    } catch {
        // Could not establish what is authorised, so authorise nothing. A 404
        // rather than a 503: an outsider learns nothing about our internals,
        // and a subscriber retries on its own schedule regardless.
        note("grant table unreadable: \(error)")
        return response(404, body: "Not found")
    }
    note("routing \(method) with \(grants.count) grant(s) loaded")

    switch FeedEndpoint.route(method: method, path: path, grants: grants) {
    case .methodNotAllowed:
        return response(405, body: "Method not allowed", headers: [
            "content-type": "text/plain; charset=utf-8",
            "allow": FeedEndpoint.allowedMethods.sorted().joined(separator: ", "),
        ])

    case .notFound:
        note("no grant matched this request")
        return response(404, body: "Not found")

    case .serve(let objectKey):
        do {
            let store = S3ObjectStore(
                bucket: try ServiceContext(actor: "feed").value("VRC_FEEDS_BUCKET"),
                region: region, accessKeyID: key, secretAccessKey: secret,
                sessionToken: sessionToken)
            let body = String(data: try store.get(key: objectKey), encoding: .utf8) ?? ""
            // HEAD gets the same headers and no body, which is what a probing
            // calendar client expects.
            let isHead = method.uppercased() == "HEAD"
            return response(200, body: isHead ? "" : body, headers: FeedEndpoint.servedHeaders)
        } catch {
            note("object read failed: \(error)")
            // The token was valid but the object is missing or unreadable.
            // Still a 404: the subscriber cannot act on the difference, and the
            // difference is exactly what we do not want to disclose.
            return response(404, body: "Not found")
        }
    }
}
