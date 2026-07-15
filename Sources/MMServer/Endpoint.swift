import MMWire

/// The endpoint enum lived in `MMServer` through Phase 3; it moved to
/// `MMWire.MMEndpoint` in Phase 4 so `MMClient` can share it without
/// depending on `MMServer`. This alias keeps all `MMServer`-facing code and
/// tests source-compatible — it is the same type, not a copy.
public typealias MMEndpoint = MMWire.MMEndpoint
