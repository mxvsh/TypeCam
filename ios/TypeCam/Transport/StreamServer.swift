//
//  StreamServer.swift
//  TypeCam
//

import Foundation
import Network

nonisolated enum ServerEvent: Sendable {
    /// A client completed the HELLO handshake.
    case connected(client: String)
    case disconnected
    case keyframeRequested
    case hostStats([String: any Sendable])
}

/// TCP server on loopback port 7878. usbmuxd forwards the Mac's connections to the device's
/// loopback interface, so nothing is exposed on Wi-Fi. One client at a time: a new
/// connection replaces the current one. All work runs on `queue`.
nonisolated final class StreamServer: @unchecked Sendable {
    var eventHandler: (@Sendable (ServerEvent) -> Void)?
    /// Supplies the HELLO_ACK fields (device name, model, app version).
    var helloInfo: (@Sendable () -> [String: Any])?

    private let queue: DispatchQueue
    private var listener: NWListener?
    private var connection: NWConnection?
    private var isReady = false
    private var lastReceive = Date.distantPast
    private var heartbeat: DispatchSourceTimer?
    private var restartPending = false

    /// Video frames handed to the network stack but not yet sent. Used for backpressure.
    private(set) var videoInFlight = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var hasClient: Bool { isReady }

    // MARK: - Listener

    func start() {
        queue.async { [self] in startListener() }
    }

    private func startListener() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Wire.port)!)
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        guard let listener = try? NWListener(using: parameters) else {
            scheduleRestart()
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.listener?.cancel()
                self.listener = nil
                self.scheduleRestart()
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Port still held by the previous process, network reset, etc. — retry shortly.
    private func scheduleRestart() {
        guard !restartPending else { return }
        restartPending = true
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            restartPending = false
            startListener()
        }
    }

    // MARK: - Connection

    private func accept(_ new: NWConnection) {
        // Newest wins: handles OBS restarting while the old socket is half-open.
        dropConnection(notify: true)
        connection = new
        videoInFlight = 0
        new.stateUpdateHandler = { [weak self, weak new] state in
            guard let self, let new, new === self.connection else { return }
            switch state {
            case .ready:
                self.lastReceive = Date()
                self.receiveHeader(on: new)
                self.startHeartbeat()
            case .failed, .cancelled:
                self.dropConnection(notify: true)
            default:
                break
            }
        }
        new.start(queue: queue)
    }

    private func dropConnection(notify: Bool) {
        guard let current = connection else { return }
        connection = nil
        current.stateUpdateHandler = nil
        current.cancel()
        heartbeat?.cancel()
        heartbeat = nil
        videoInFlight = 0
        let wasReady = isReady
        isReady = false
        if notify && wasReady { eventHandler?(.disconnected) }
    }

    func disconnect() {
        queue.async { [self] in dropConnection(notify: true) }
    }

    // MARK: - Receiving

    private func receiveHeader(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: Wire.headerSize, maximumLength: Wire.headerSize) { [weak self] data, _, isComplete, error in
            guard let self, conn === self.connection else { return }
            guard error == nil, !isComplete, let data, let header = Wire.decodeHeader(data) else {
                self.dropConnection(notify: true)
                return
            }
            self.lastReceive = Date()
            if header.length == 0 {
                self.handle(header, payload: Data(), on: conn)
                self.receiveHeader(on: conn)
            } else {
                self.receivePayload(header, on: conn)
            }
        }
    }

    private func receivePayload(_ header: Wire.Header, on conn: NWConnection) {
        let length = Int(header.length)
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, conn === self.connection else { return }
            guard error == nil, let data, data.count == length else {
                self.dropConnection(notify: true)
                return
            }
            self.lastReceive = Date()
            self.handle(header, payload: data, on: conn)
            self.receiveHeader(on: conn)
        }
    }

    private func handle(_ header: Wire.Header, payload: Data, on conn: NWConnection) {
        // Unknown types are ignored, per the protocol.
        guard let type = MessageType(rawValue: header.type) else { return }
        switch type {
        case .hello:
            let hello = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
            let version = hello["protocol_version"] as? Int ?? 0
            var ack = helloInfo?() ?? [:]
            ack["protocol_version"] = Wire.protocolVersion
            guard version == Wire.protocolVersion else {
                ack["ok"] = false
                ack["error"] = "Protocol version \(version) not supported; this app speaks v\(Wire.protocolVersion). Update TypeCam and the OBS plugin."
                send(.helloAck, payload: Wire.json(ack))
                queue.asyncAfter(deadline: .now() + 0.5) { [self] in dropConnection(notify: false) }
                return
            }
            ack["ok"] = true
            send(.helloAck, payload: Wire.json(ack))
            isReady = true
            eventHandler?(.connected(client: hello["client"] as? String ?? "unknown"))
        case .ping:
            send(.pong, payload: payload)
        case .keyframeRequest:
            eventHandler?(.keyframeRequested)
        case .hostStats:
            if let stats = (try? JSONSerialization.jsonObject(with: payload)) as? [String: any Sendable] {
                eventHandler?(.hostStats(stats))
            }
        default:
            break
        }
    }

    // MARK: - Sending

    /// Must be called on `queue`.
    func send(_ type: MessageType, flags: UInt8 = 0, pts: UInt64 = 0, payload: Data) {
        guard let connection else { return }
        let isVideo = type == .videoFrame
        if isVideo { videoInFlight += 1 }
        var message = Wire.encodeHeader(type, flags: flags, length: payload.count, pts: pts)
        message.append(payload)
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            guard let self, connection === self.connection else { return }
            if isVideo { self.videoInFlight = max(0, self.videoInFlight - 1) }
            if error != nil { self.dropConnection(notify: true) }
        })
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReceive) > 3 {
                self.dropConnection(notify: true)
                return
            }
            var stamp = Data()
            withUnsafeBytes(of: DispatchTime.now().uptimeNanoseconds.littleEndian) { stamp.append(contentsOf: $0) }
            self.send(.ping, payload: stamp)
        }
        timer.resume()
        heartbeat = timer
    }
}
