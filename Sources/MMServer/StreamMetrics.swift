import Metrics

/// The per-connection stream metric handles, bundled so the stream table,
/// sources, and sinks share one set. Same label style as ``MMService``'s
/// connection/frame counters (`mm_server_*_total`).
///
/// Counters are process-global by label in swift-metrics, so constructing this
/// struct per connection reuses the same underlying counters — the bundle just
/// saves threading each handle through every stream type.
struct MMStreamMetrics: Sendable {
    /// Streams opened (an accepted kind-1 open on a stream route).
    let opened: Counter
    /// Streams that reached their terminal via graceful END/return.
    let ended: Counter
    /// Streams where a STOP was observed in either direction.
    let stopped: Counter
    /// Streams cancelled (client CANCEL) — the runtime sent a code-7 terminal.
    let cancelled: Counter
    /// Request (inbound) items accepted and delivered to a handler.
    let itemsIn: Counter
    /// Response (outbound) items written to the wire.
    let itemsOut: Counter
    /// Times a response `send` parked at zero credit.
    let creditStalls: Counter
    /// Additive credit grants written to the client for a request stream.
    let creditGrantsOut: Counter
    /// STOP frames the server sent (server-initiated request-stream STOP).
    let stopsOut: Counter
    /// Stream-contract violations that produced a code-6 terminal.
    let violations: Counter
    /// Opens rejected over `maxConcurrentStreamsPerConnection` (code-4 terminal).
    let overCap: Counter

    init() {
        self.init(factory: nil)
    }

    /// Constructs the bundle against an explicit ``MetricsFactory`` (or the
    /// global one when nil). Tests inject a private capturing factory so they can
    /// assert increments without touching — or racing — process-global counters.
    init(factory: (any MetricsFactory)?) {
        func counter(_ label: String) -> Counter {
            if let factory {
                return Counter(label: label, dimensions: [], factory: factory)
            }
            return Counter(label: label)
        }
        self.opened = counter("mm_server_streams_opened_total")
        self.ended = counter("mm_server_streams_ended_total")
        self.stopped = counter("mm_server_streams_stopped_total")
        self.cancelled = counter("mm_server_streams_cancelled_total")
        self.itemsIn = counter("mm_server_stream_items_in_total")
        self.itemsOut = counter("mm_server_stream_items_out_total")
        self.creditStalls = counter("mm_server_stream_credit_stalls_total")
        self.creditGrantsOut = counter("mm_server_stream_credit_grants_out_total")
        self.stopsOut = counter("mm_server_stream_stops_out_total")
        self.violations = counter("mm_server_stream_violations_total")
        self.overCap = counter("mm_server_streams_over_cap_total")
    }
}
