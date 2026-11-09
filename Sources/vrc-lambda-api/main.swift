import Foundation
import VRCCore
import VRCLambda

// Reads on behalf of the owner's own application, so 'owner'. Every write path
// the API exposes still passes through the same database guards.
let context = ServiceContext(actor: "owner")

LambdaRuntime.run { invocation in
    let event = LambdaJSON.object(invocation.payload)
    let request = ApiHandler.Request(event: event)
    do {
        // Assembled over the repositories, so the handler runs tested
        // operations rather than its own SQL.
        let rental = try RentalStore.makeCloud(store: try context.store())
        return ApiHandler(context: context).handle(request, rental: rental)
    } catch {
        // Fail closed: an unconfigured or unreachable database is 503, never an
        // empty-but-successful answer that the Mac would read as "all clear".
        return LambdaJSON.httpResponse(503, [
            "error": "database unavailable",
            "detail": (error as? LocalizedError)?.errorDescription ?? "\(error)",
            "remoteSynchronised": false,
        ])
    }
}
