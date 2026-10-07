//
//  StreamState.swift
//  TypeCam
//

/// Connection state shown by the stream-state button. Driven by `StreamServer` from M2;
/// until then the app stays in `.waiting`.
nonisolated enum StreamState: Sendable {
    /// No OBS client connected.
    case waiting
    /// Client connected and media is flowing.
    case live
    /// Client connected but the user paused sending.
    case paused
}
