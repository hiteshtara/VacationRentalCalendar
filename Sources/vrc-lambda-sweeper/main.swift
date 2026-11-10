import Foundation
import VRCCore
import VRCLambda

// 'owner' rather than 'importer': releasing an EXPIRED hold is a legitimate
// lifecycle action, not an inference drawn from a feed. It still cannot touch a
// confirmed reservation — the UPDATE only matches holds.
let context = ServiceContext(actor: "owner")

LambdaRuntime.run { _ in
    let outcome = try SweeperHandler(context: context).run(store: try context.store())
    return LambdaJSON.data([
        "holdsReleased": outcome.holdsReleased,
        "detail": outcome.detail,
    ])
}
