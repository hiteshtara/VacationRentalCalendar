import Foundation
import VRCCore
import VRCLambda

let context = ServiceContext(actor: "owner")

LambdaRuntime.run { invocation in
    // Checked before anything is read, so a disabled gate costs nothing and
    // cannot be bypassed by a malformed request.
    guard OutboundSyncGate.isEnabled, context.outboundEnabled else {
        return LambdaJSON.data([
            "stage": "refused",
            "detail": "outbound publication is disabled: "
                + "OutboundSyncGate.isEnabled=\(OutboundSyncGate.isEnabled), "
                + "VRC_OUTBOUND_ENABLED=\(context.outboundEnabled)",
            "remoteSynchronised": false,
        ])
    }

    let environment = ProcessInfo.processInfo.environment
    guard let key = environment["AWS_ACCESS_KEY_ID"],
          let secret = environment["AWS_SECRET_ACCESS_KEY"] else {
        throw LambdaRuntime.HandlerError(
            type: "Misconfigured", message: "no AWS credentials in the environment")
    }
    let region = environment["AWS_REGION"] ?? "us-east-1"
    let token = environment["AWS_SESSION_TOKEN"]

    _ = PublishHandler(
        context: context,
        objects: S3ObjectStore(
            bucket: try context.value("VRC_FEEDS_BUCKET"), region: region,
            accessKeyID: key, secretAccessKey: secret, sessionToken: token),
        invalidator: CloudFrontInvalidator(
            distributionID: try context.value("VRC_FEEDS_DIST_ID"),
            accessKeyID: key, secretAccessKey: secret, sessionToken: token))

    // Reaching here means the gate was opened deliberately. Wiring the
    // generator to live decisions is the step that comes after authorisation,
    // and it is left unwritten on purpose rather than left disabled.
    return LambdaJSON.data([
        "stage": "refused",
        "detail": "the gate is open but live publication is not yet wired, by design",
        "remoteSynchronised": false,
    ])
}
