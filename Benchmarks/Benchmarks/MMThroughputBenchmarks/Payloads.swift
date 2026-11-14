import MMSchema
import MMWire
import NIOCore

/// The payloads the throughput benchmarks move, declared the way an
/// application declares its contract, so every stage runs on generated types.
/// Each payload has the three calls that move it:
///
/// - `echo`, two-way: the response is the request.
/// - `send`, one-way from client to server: a client stream, answered once
///   with the number of elements received.
/// - `receive`, one-way from server to client: a server stream of as many
///   copies as the request's count, answered with the number sent.
enum Throughput: MethodNamespace {
    #schema("throughput") {
        Enum("Condition") {
            Case("new")
            Case("used")
        }
        Type("Item") {
            Field("sku", .string)
            Field("name", .string)
            Field("quantity", .int)
            Field("price", .double)
            Field("condition", "Condition")
            Field("tags", .array(.string))
            Field("note", .optional(.string))
        }
        // One integer: the smallest message, close to each stage's fixed cost.
        Type("Scalar") {
            Field("value", .int)
        }
        // One record of mixed field types: a typical request.
        Type("Record") {
            Field("item", "Item")
        }
        // A hundred records: a typical listing.
        Type("Listing") {
            Field("items", .array(.reference("Item")))
        }
        // How many elements a stream carries.
        Type("Count") {
            Field("count", .int)
        }

        Call("echoScalar") {
            Access { .write }
            Request(.reference("Scalar"))
            Response(.reference("Scalar"))
        }
        Call("sendScalar") {
            Access { .write }
            Request(.reference("Count"))
            RequestStream(.reference("Scalar"))
            Response(.reference("Count"))
        }
        Call("receiveScalar") {
            Access { .read }
            Request(.reference("Count"))
            ResponseStream(.reference("Scalar"))
            Response(.reference("Count"))
        }

        Call("echoRecord") {
            Access { .write }
            Request(.reference("Record"))
            Response(.reference("Record"))
        }
        Call("sendRecord") {
            Access { .write }
            Request(.reference("Count"))
            RequestStream(.reference("Record"))
            Response(.reference("Count"))
        }
        Call("receiveRecord") {
            Access { .read }
            Request(.reference("Count"))
            ResponseStream(.reference("Record"))
            Response(.reference("Count"))
        }

        Call("echoListing") {
            Access { .write }
            Request(.reference("Listing"))
            Response(.reference("Listing"))
        }
        Call("sendListing") {
            Access { .write }
            Request(.reference("Count"))
            RequestStream(.reference("Listing"))
            Response(.reference("Count"))
        }
        Call("receiveListing") {
            Access { .read }
            Request(.reference("Count"))
            ResponseStream(.reference("Listing"))
            Response(.reference("Count"))
        }
    }
}

/// A payload the throughput benchmarks move, with the calls that move it.
protocol ThroughputPayload: MMPackCodable, Codable, Hashable, Sendable {
    /// The payload's name in benchmark names.
    static var shape: String { get }
    /// What every message of this payload carries.
    static var sample: Self { get }
    static var echo: Method<Self, Self> { get }
    static var send: ClientStreamMethod<Throughput.Count, Self, Throughput.Count> { get }
    static var receive: ServerStreamMethod<Throughput.Count, Self, Throughput.Count> { get }
}

extension Throughput.Scalar: ThroughputPayload {
    static let shape = "scalar"
    static let sample = Throughput.Scalar(value: 42)
    static var echo: Method<Self, Self> { Throughput.echoScalar }
    static var send: ClientStreamMethod<Throughput.Count, Self, Throughput.Count> {
        Throughput.sendScalar
    }
    static var receive: ServerStreamMethod<Throughput.Count, Self, Throughput.Count> {
        Throughput.receiveScalar
    }
}

extension Throughput.Record: ThroughputPayload {
    static let shape = "record"
    static let sample = Throughput.Record(item: .sample(1))
    static var echo: Method<Self, Self> { Throughput.echoRecord }
    static var send: ClientStreamMethod<Throughput.Count, Self, Throughput.Count> {
        Throughput.sendRecord
    }
    static var receive: ServerStreamMethod<Throughput.Count, Self, Throughput.Count> {
        Throughput.receiveRecord
    }
}

extension Throughput.Listing: ThroughputPayload {
    static let shape = "listing"
    static let sample = Throughput.Listing(items: (0..<100).map(Throughput.Item.sample))
    static var echo: Method<Self, Self> { Throughput.echoListing }
    static var send: ClientStreamMethod<Throughput.Count, Self, Throughput.Count> {
        Throughput.sendListing
    }
    static var receive: ServerStreamMethod<Throughput.Count, Self, Throughput.Count> {
        Throughput.receiveListing
    }
}

extension Throughput.Item {
    static func sample(_ index: Int) -> Throughput.Item {
        Throughput.Item(
            sku: "SKU-\(100_000 + index)",
            name: "Stainless steel water bottle",
            quantity: index,
            price: 24.5,
            condition: index.isMultiple(of: 3) ? .used : .new,
            tags: ["kitchen", "outdoor", "gift"],
            note: index.isMultiple(of: 2) ? "Restocked on Friday" : nil
        )
    }
}

/// The frames a payload's messages travel in, each with its length prefix:
/// a stream element, and a call's request and response.
struct ThroughputFrames {
    let item: ByteBuffer
    let request: ByteBuffer
    let response: ByteBuffer

    init<Payload: ThroughputPayload>(_ payload: Payload.Type) {
        let encoded = try! MMPackEncoder().encode(Payload.sample).get()
        self.item = framed(.item(msgid: 1, seq: 0, item: encoded))
        self.request = framed(
            .request(msgid: 1, method: Payload.echo.name, entity: throughputEntity, params: encoded)
        )
        self.response = framed(.response(msgid: 1, error: nil, result: encoded))
    }
}

/// The entity every benchmark call targets; the benchmark's own user owns it.
let throughputEntity = "throughput"

/// Why a total benchmark's server, client or run failed. The fixtures are
/// known-good, so any of these is a broken benchmark, not a measurement.
enum ThroughputFailure: Error {
    case server(String)
    case client(String)
    case run(String)
}

/// `envelope` with its length prefix. The fixtures are known-good, so a
/// failure here is a broken benchmark, not a measurement.
func framed(_ envelope: MMEnvelope) -> ByteBuffer {
    var frame = ByteBuffer()
    try! MMFrameEncoder().encode(data: try! envelope.encoded().get(), out: &frame)
    return frame
}
