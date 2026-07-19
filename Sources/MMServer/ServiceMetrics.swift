import Metrics

/// The server-lifecycle metric handles, bundled like ``MMStreamMetrics`` and
/// the client's `ClientMetrics`: one set per concern instead of loose fields.
/// Counters are process-global by label in swift-metrics, so construction is
/// cheap and label-stable.
struct ServiceMetrics: Sendable {
    let connectionsAccepted = Counter(label: "mm_server_connections_accepted_total")
    let connectionsRejected = Counter(label: "mm_server_connections_rejected_total")
    let framesIn = Counter(label: "mm_server_frames_in_total")
    let framesOut = Counter(label: "mm_server_frames_out_total")
    let protocolViolations = Counter(label: "mm_server_protocol_violations_total")
    let acceptFailures = Counter(label: "mm_server_accept_failures_total")
    let activeConnections = Gauge(label: "mm_server_active_connections")
    let streamFramesDropped = Counter(label: "mm_server_stream_frames_dropped_total")
}

/// The router's dispatch metric handles.
struct RouterMetrics: Sendable {
    let authorizationDenials = Counter(label: "mm_server_auth_denials_total")
    let inboundResponsesDropped = Counter(label: "mm_server_inbound_responses_dropped_total")
    let streamFramesDropped = Counter(label: "mm_server_stream_frames_dropped_total")
    let dispatchDuration = Metrics.Timer(label: "mm_server_dispatch_duration_ns")
}
