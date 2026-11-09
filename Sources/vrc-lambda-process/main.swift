import Foundation
import VRCCore
import VRCLambda

let context = ServiceContext(actor: "importer")

LambdaRuntime.run { invocation in
    let event = LambdaJSON.object(invocation.payload)
    guard let source = event["source"] as? String,
          let payloadKey = event["payloadKey"] as? String else {
        throw LambdaRuntime.HandlerError(
            type: "BadRequest", message: "expected source and payloadKey")
    }

    let environment = ProcessInfo.processInfo.environment
    guard let key = environment["AWS_ACCESS_KEY_ID"],
          let secret = environment["AWS_SECRET_ACCESS_KEY"] else {
        throw LambdaRuntime.HandlerError(
            type: "Misconfigured", message: "no AWS credentials in the environment")
    }
    let region = environment["AWS_REGION"] ?? "us-east-1"

    let handler = ProcessHandler(
        context: context,
        objects: S3ObjectStore(
            bucket: try context.value("VRC_RAW_BUCKET"), region: region,
            accessKeyID: key, secretAccessKey: secret,
            sessionToken: environment["AWS_SESSION_TOKEN"]))

    let outcome = try handler.run(
        source: source, payloadKey: payloadKey, store: try context.store())

    return LambdaJSON.data([
        "source": outcome.source,
        "seen": outcome.seen,
        "updated": outcome.updated,
        "withdrawn": outcome.withdrawn,
        "withdrawalRefused": outcome.withdrawalRefused ?? "",
        "classificationsPreserved": outcome.classificationsPreserved,
        "detail": outcome.detail,
    ])
}
