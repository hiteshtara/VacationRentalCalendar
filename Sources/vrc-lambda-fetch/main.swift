import Foundation
import VRCCore
import VRCLambda

// Holds no database credential by design. See FetchHandler.

let context = ServiceContext(actor: "importer")

LambdaRuntime.run { invocation in
    let environment = ProcessInfo.processInfo.environment
    guard let key = environment["AWS_ACCESS_KEY_ID"],
          let secret = environment["AWS_SECRET_ACCESS_KEY"] else {
        throw LambdaRuntime.HandlerError(
            type: "Misconfigured", message: "no AWS credentials in the environment")
    }
    let region = environment["AWS_REGION"] ?? "us-east-1"
    let token = environment["AWS_SESSION_TOKEN"]

    let secrets = SecretsManagerReader(
        region: region, accessKeyID: key, secretAccessKey: secret, sessionToken: token)
    // The inbound feed URLs. This is the only secret this function may read,
    // and it is never logged.
    let urls = try secrets.secret(id: try context.value("VRC_SOURCE_SECRET_ARN"))

    let handler = FetchHandler(
        context: context,
        fetcher: URLSessionFeedFetcher(),
        objects: S3ObjectStore(
            bucket: try context.value("VRC_RAW_BUCKET"), region: region,
            accessKeyID: key, secretAccessKey: secret, sessionToken: token),
        invoker: LambdaFunctionInvoker(
            region: region, accessKeyID: key, secretAccessKey: secret, sessionToken: token))

    // Disconnected sources are not polled at all: Booking.com's token was
    // revoked, and retrying it would be noise, not diligence.
    let disconnected = Set((environment["VRC_DISCONNECTED_SOURCES"] ?? "booking_com")
        .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })

    let sources = urls.keys.sorted()
        .filter { !disconnected.contains($0) }
        .compactMap { name -> FetchHandler.Source? in
            urls[name].map { FetchHandler.Source(name: name, url: $0) }
        }

    let outcome = try handler.run(sources: sources)
    return LambdaJSON.data([
        "checked": outcome.checked,
        "changed": outcome.changed,
        "unchanged": outcome.unchanged,
        "notModified": outcome.notModified,
        "failed": outcome.failed,
        "skippedDisconnected": Array(disconnected).sorted(),
    ])
}
