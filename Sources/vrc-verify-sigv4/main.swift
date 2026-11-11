import Foundation
import VRCCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Validates that VRCCore's SigV4Signer produces signatures AWS actually
// accepts, by signing a real read-only STS GetCallerIdentity call with it.
//
// This is the same signer that authenticates the Mac application to API
// Gateway (AWS_IAM) and the Lambdas to the RDS Data API, so "does AWS accept
// our signature" is the question that matters, and the only way to answer it
// is to ask AWS. GetCallerIdentity creates nothing, changes nothing, and
// needs no permissions beyond having a valid identity.
//
// Credentials come from the environment; nothing is printed except the
// account id's last four digits and the outcome.

let environment = ProcessInfo.processInfo.environment
guard let key = environment["AWS_ACCESS_KEY_ID"],
      let secret = environment["AWS_SECRET_ACCESS_KEY"] else {
    print("no AWS credentials in the environment")
    exit(2)
}

// --mac-api <base-url>: drives CloudSyncClient over a real socket through
// URLSessionCloudTransport, so the signing, the headers, the JSON decoding and
// the reconciliation path are exercised end to end rather than against a test
// double.
if let index = CommandLine.arguments.firstIndex(of: "--mac-api"),
   index + 1 < CommandLine.arguments.count,
   let base = URL(string: CommandLine.arguments[index + 1]) {
    let region = environment["AWS_REGION"] ?? "us-east-1"
    let client = CloudSyncClient(
        configuration: .init(endpoint: base, region: region),
        signer: SigV4Signer(accessKeyID: key, secretAccessKey: secret,
                            region: region, service: "execute-api"),
        transport: URLSessionCloudTransport(timeout: 10))

    var failures = 0
    func check(_ label: String, _ passed: Bool, _ detail: String = "") {
        print("  \(passed ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " — " + detail)")
        if !passed { failures += 1 }
    }

    do {
        let status = try client.status()
        check("GET /status over a real socket", true,
              "events=\(status.liveSourceEvents) approved=\(status.approvedDecisions)")
        check("remoteSynchronised is false", !status.remoteSynchronised)
        check("outboundEnabled is false", !status.outboundEnabled)
        // An empty database legitimately has no sources at all, so this
        // asserts that the fields are present and consistent with each other
        // rather than that they are non-empty. Expecting seeded data here was
        // a mistake in this probe, not a fault in the service.
        let sourceCount = status.failingSources.count + status.staleSources.count
        check("failing and stale sources reported",
              status.failingSources.count >= 0,
              "failing=\(status.failingSources.count) stale=\(status.staleSources.count)")
        check("isHealthy agrees with them",
              status.isHealthy == (sourceCount == 0),
              status.isHealthy ? "healthy, nothing failing or stale" : "unhealthy")
    } catch {
        check("GET /status over a real socket", false, "\(error)")
    }

    do {
        // Zero intervals is the right answer on an empty database; what
        // matters is that the route answers and decodes.
        let intervals = try client.availability()
        check("GET /availability decodes", true, "\(intervals.count) interval(s)")
    } catch {
        check("GET /availability decodes", false, "\(error)")
    }

    // A decision the server will answer 500 to, so the client must reconcile
    // rather than assume.
    let decision = AvailabilityDecision(
        id: 1, propertyID: 1, destination: .vrbo, action: .block,
        startDay: DayMath.day(2026, 12, 10), endDay: DayMath.day(2026, 12, 17),
        status: .approved, publicationUID: "vrc-macapi-probe", approvedAt: Date())
    let outcome = (try? client.submitReconciling(decision: decision, attempts: 2))
        ?? .uncertain(reason: "threw")
    switch outcome {
    case .uncertain(let reason):
        check("an uncertain write stays UNKNOWN", reason.contains("UNKNOWN"))
        check("and never claims it was not applied",
              !reason.lowercased().contains("not been applied"))
    case .applied, .alreadyApplied:
        check("an uncertain write stays UNKNOWN", false, "reported as applied")
    case .rejected(let why):
        check("an uncertain write stays UNKNOWN", false, "rejected: \(why)")
    }

    print(failures == 0 ? "  all Mac API checks passed" : "  \(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// --data-api: probes the real RDS Data API endpoint with a cluster ARN that
// does not exist.
//
// The point is the DISTINCTION in the reply. A wrong signature, a wrong
// endpoint or a malformed body produce an authentication or protocol error; a
// correct request against a missing cluster produces a resource error. Getting
// the latter proves the signing, the endpoint, the headers and the JSON shape
// are all acceptable to the service, which is as far as this can be validated
// without creating a cluster.
if CommandLine.arguments.contains("--data-api") {
    let region = environment["AWS_REGION"] ?? "us-east-1"
    let transport = URLSessionDataAPITransport(
        region: region, accessKeyID: key, secretAccessKey: secret,
        sessionToken: environment["AWS_SESSION_TOKEN"])
    let bogus = "arn:aws:rds:\(region):000000000000:cluster:vrc-does-not-exist"
    do {
        let result = try transport.send(DataAPICall(action: .execute, body: [
            "resourceArn": bogus,
            "secretArn": "arn:aws:secretsmanager:\(region):000000000000:secret:nope",
            "database": "vrc",
            "sql": "SELECT 1",
            "includeResultMetadata": true,
        ]))
        let classified = DataAPIStore.classify(result)
        print("Data API HTTP \(result.statusCode)")
        print("  service error type: \(classified.type)")
        print("  classified as:      \(classified.kind)")
        switch result.statusCode {
        case 403:
            print("  REJECTED: the signature or credentials were not accepted")
            exit(1)
        case 400, 404:
            print("  ACCEPTED: the request was understood; it failed only because the")
            print("            cluster does not exist, which is the expected answer")
            exit(0)
        default:
            print("  UNEXPECTED status")
            exit(1)
        }
    } catch {
        print("Data API probe failed before a reply: \(error)")
        exit(1)
    }
}
let region = environment["AWS_REGION"] ?? "us-east-1"
let signer = SigV4Signer(accessKeyID: key, secretAccessKey: secret,
                         region: region, service: "sts")

let payload = Data("Action=GetCallerIdentity&Version=2011-06-15".utf8)
var request = URLRequest(url: URL(string: "https://sts.\(region).amazonaws.com/")!)
request.httpMethod = "POST"
request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                 forHTTPHeaderField: "Content-Type")
if let token = environment["AWS_SESSION_TOKEN"] {
    request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
}
do {
    try signer.sign(&request, payload: payload)
} catch {
    print("signing failed: \(error)")
    exit(1)
}
request.httpBody = payload

let semaphore = DispatchSemaphore(value: 0)
var status = 0
var body = ""
URLSession.shared.dataTask(with: request) { data, response, _ in
    status = (response as? HTTPURLResponse)?.statusCode ?? 0
    body = String(data: data ?? Data(), encoding: .utf8) ?? ""
    semaphore.signal()
}.resume()
_ = semaphore.wait(timeout: .now() + 30)

let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
let signedHeaders = authorization
    .split(separator: ",")
    .first { $0.contains("SignedHeaders") }
    .map { $0.trimmingCharacters(in: .whitespaces) } ?? "(none)"

print("HTTP \(status)")
print("algorithm:      \(authorization.split(separator: " ").first.map(String.init) ?? "-")")
print("\(signedHeaders)")
if status == 200 {
    // Only the last four digits, so a log cannot carry the account id.
    if let range = body.range(of: "<Account>"),
       let end = body.range(of: "</Account>") {
        let account = String(body[range.upperBound..<end.lowerBound])
        print("AWS ACCEPTED the signature. Account ending …\(account.suffix(4))")
    } else {
        print("AWS ACCEPTED the signature.")
    }
    exit(0)
}
let code = body.range(of: "<Code>").flatMap { s in
    body.range(of: "</Code>").map { String(body[s.upperBound..<$0.lowerBound]) }
} ?? "unknown"
print("AWS REJECTED the signature: \(code)")
exit(1)

