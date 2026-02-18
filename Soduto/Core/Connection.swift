//
//  Connection.swift
//  Soduto
//
//  Created by Sannidhya Roy on 15/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import NIOFoundationCompat
import os

// MARK: - Connection Configuration

public protocol ConnectionConfiguration: HostConfiguration {
    var hostCertificate: SecIdentity? { get }
    func deviceConfig(for deviceId: Device.Id) -> DeviceConfiguration
    func knownDeviceConfigs() -> [DeviceConfiguration]
}

// MARK: - Connection Delegate

/// Delegate protocol for Connection events.
public protocol ConnectionDelegate: AnyObject {
    func connection(_ connection: Connection, didSwitchToState state: Connection.State)
    func connection(_ connection: Connection, didSendPacket packet: DataPacket, uploadedPayload: Bool)
    func connection(_ connection: Connection, didReadPacket packet: DataPacket)
    func connectionCapacityChanged(_ connection: Connection)
}

// MARK: - Connection

/// Manages a TCP connection with TLS for KDE Connect protocol communication.
///
/// This class manages a TCP connection with TLS using SwiftNIO. It supports
/// STARTTLS with role reversal as required by KDE Connect protocol.
public class Connection: NSObject, PairingHandlerDelegate, UploadTaskDelegate {
    
    // MARK: Types
    
    public enum ConnectionError: Error {
        case channelNotAvailable
        case identityNotSet
        case initializationAlreadyFinished
        case tlsUpgradeFailed(Error)
        case serializationFailed
    }
    
    public enum State {
        case Initializing
        case Open
        case Closed
    }
    
    public typealias SendingCompletionHandler = ((_ packetSent: Bool, _ payloadSent: Bool) -> Void)
    
    public struct DataPacketSendingInfo {
        let dataPacket: DataPacket
        let uploadTask: UploadTask?
        let completionHandler: SendingCompletionHandler?
        var packetSent: Bool? = nil
        var payloadSent: Bool? = nil
        
        init(dataPacket: DataPacket, uploadTask: UploadTask?, completionHandler: SendingCompletionHandler?) {
            self.dataPacket = dataPacket
            self.uploadTask = uploadTask
            self.completionHandler = completionHandler
            if self.uploadTask == nil {
                self.payloadSent = false
            }
        }
    }
    
    // MARK: Properties
    
    public weak var delegate: ConnectionDelegate?
    public weak var pairingDelegate: PairableDelegate?
    
    public private(set) var state: State {
        didSet {
            if oldValue != self.state {
                // Notify delegate on main queue
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.connection(self, didSwitchToState: self.state)
                }
            }
            
            if self.state == .Open && self.pairingStatus == .Paired {
                self.rememberHwAddress()
            }
        }
    }
    
    public private(set) var identity: DataPacket? = nil
    public private(set) var peerCertificate: SecCertificate? = nil
    public private(set) var peerAddress: SocketAddress
    
    public var hostCertificate: SecCertificate? { return self.config.hostCertificate?.certificate }
    
    /// The NIO channel for this connection.
    private var channel: Channel?
    
    /// The event loop group (shared).
    private let eventLoopGroup: EventLoopGroup
    
    private let config: ConnectionConfiguration
    private let hostIdentity: SecIdentity
    private let uploadQueue: DispatchQueue
    private let downloadQueue: DispatchQueue
    private var packetsSending: [DataPacketSendingInfo] = []
    private var packetsExpected: Int = 0
    private var waitingToSecure: Bool = false
    private var shouldFinishIntializationWhenSecured: Bool = false
    private var pairingHandler: DefaultPairingHandler? = nil
    
    /// Trust handler for TLS verification.
    private var trustHandler: TrustHandler?
    
    /// Reference to the packet handler in the pipeline.
    private var connectionHandler: ConnectionHandler?
    
    /// If true, connection will close after all pending uploads complete.
    private var shouldCloseAfterUploads: Bool = false
    
    // MARK: Initialization / Deinitialization
    
    /// Creates an outgoing connection to the specified address.
    ///
    /// - Parameters:
    ///   - address: The socket address to connect to.
    ///   - identityPacket: The identity packet received from the peer.
    ///   - config: The connection configuration.
    ///   - eventLoopGroup: The NIO event loop group to use.
    init?(address: SocketAddress, identityPacket packet: DataPacket, config: ConnectionConfiguration, eventLoopGroup: EventLoopGroup) {
        guard let hostIdentity = config.hostCertificate else { return nil }
        
        self.peerAddress = address
        self.config = config
        self.hostIdentity = hostIdentity
        self.eventLoopGroup = eventLoopGroup
        self.state = .Initializing
        self.uploadQueue = Connection.createDispatchQueue(withLabel: "Payload upload queue")
        self.downloadQueue = Connection.createDispatchQueue(withLabel: "Payload download queue")
        
        super.init()
        
        do {
            try self.applyIdentity(packet: packet)
        } catch {
            Logger.network.error("Failed to apply identity: \(error, privacy: .public)")
            return nil
        }
        
        // Connect to peer
        self.connectToAddress(address)
    }
    
    /// Creates an incoming connection from an accepted NIO channel.
    ///
    /// - Parameters:
    ///   - channel: The accepted NIO channel.
    ///   - config: The connection configuration.
    ///   - eventLoopGroup: The NIO event loop group.
    init?(channel: Channel, config: ConnectionConfiguration, eventLoopGroup: EventLoopGroup) {
        guard let hostIdentity = config.hostCertificate else { return nil }
        guard let remoteAddress = channel.remoteAddress else { return nil }
        
        // Convert NIOCore.SocketAddress to SocketAddress
        let peerAddr: SocketAddress
        switch remoteAddress {
        case .v4(let addr):
            peerAddr = SocketAddress(addr: addr.address)
        case .v6(let addr):
            peerAddr = SocketAddress(addr: addr.address)
        default:
            return nil
        }
        
        self.peerAddress = peerAddr
        self.config = config
        self.hostIdentity = hostIdentity
        self.eventLoopGroup = eventLoopGroup
        self.channel = channel
        self.state = .Initializing
        self.uploadQueue = Connection.createDispatchQueue(withLabel: "Payload upload queue")
        self.downloadQueue = Connection.createDispatchQueue(withLabel: "Payload download queue")
        
        super.init()
        
        // Set up the channel pipeline
        self.setupChannelPipeline(channel: channel).whenFailure { [weak self] error in
            Logger.network.error("Failed to set up connection pipeline: \(error, privacy: .public)")
            self?.close()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        self.state = .Closed
        self.channel?.close(promise: nil)
    }
    
    // MARK: Public API
    
    public func applyIdentity(packet: DataPacket) throws {
        guard self.state == .Initializing else {
            throw ConnectionError.initializationAlreadyFinished
        }
        
        try packet.validateIdentityType()
        let deviceId = try packet.getDeviceId()
        let deviceConfig = self.config.deviceConfig(for: deviceId)
        
        self.identity = packet
        self.pairingHandler = DefaultPairingHandler(config: deviceConfig)
        self.pairingHandler!.delegate = self
        // Note: pairingHandler's pairingDelegate and impersonateAs are NOT set because
        // Connection handles pairing packets directly in handlePairingPacket()
        // and uses PairableDelegate for pairing events
    }
    
    public func secureServer() {
        assert(self.state == .Initializing, "Connection initialization already finished")
        assert(self.identity != nil, "Identity expected to be known before securing connection")
        
        self.waitingToSecure = true
        self.performTLSUpgrade(role: .server)
    }
    
    public func secureClient() {
        assert(self.state == .Initializing, "Connection initialization already finished")
        assert(self.identity != nil, "Identity expected to be known before securing connection")
        
        self.waitingToSecure = true
        self.performTLSUpgrade(role: .client)
    }
    
    public func finishInitialization() {
        assert(self.state == .Initializing, "Connection initialization already finished")
        assert(self.identity != nil, "Connection identity must be set before finishing initialization")
        
        if !self.waitingToSecure {
            self.state = .Open
        } else {
            self.shouldFinishIntializationWhenSecured = true
        }
        
        self.observeNotifications()
    }
    
    /// Try sending a packet with completion handler.
    public func send(_ dataPacket: DataPacket, whenCompleted: SendingCompletionHandler? = nil) -> Bool {
        if dataPacket.hasPayload() {
            return self.sendPayloadPacket(dataPacket, whenCompleted: whenCompleted)
        } else {
            return self.sendSimplePacket(dataPacket, whenCompleted: whenCompleted)
        }
    }
    
    public func send(_ dataPacket: DataPacket) -> Bool {
        return self.send(dataPacket, whenCompleted: nil)
    }
    
    public func readOnePacket() {
        self.packetsExpected = 1
        // NIO reads automatically via pipeline - just track expected count
    }
    
    public func readPackets() {
        self.packetsExpected = -1
        // NIO reads automatically via pipeline
    }
    
    public func reclaimUnsentPackets() -> [(dataPacket: DataPacket, completionHandler: SendingCompletionHandler?)] {
        assert(self.state == .Closed)
        return self.discardUnsentPackets(silently: true)
    }
    
    public func close() {
        self.channel?.close(promise: nil)
    }
    
    public func closeAfterWriting() {
        if self.hasActiveUploadTasks {
            // Don't close yet - set flag to close after uploads complete
            Logger.network.debug("Connection: deferring close until uploads complete")
            self.shouldCloseAfterUploads = true
        } else {
            self.channel?.close(mode: .output, promise: nil)
        }
    }
    
    /// Returns true if there are active upload tasks that haven't completed yet.
    public var hasActiveUploadTasks: Bool {
        return self.packetsSending.contains { info in
            guard let uploadTask = info.uploadTask else { return false }
            return uploadTask.isStarted && info.payloadSent == nil
        }
    }
    
    /// Extracts active upload tasks from this connection for transfer to another owner.
    /// The tasks are removed from this connection and returned.
    /// This prevents the upload tasks from being closed when this connection closes.
    public func extractActiveUploadTasks() -> [UploadTask] {
        var activeTasks: [UploadTask] = []
        var indicesToRemove: [Int] = []
        
        for (index, info) in self.packetsSending.enumerated() {
            if let uploadTask = info.uploadTask, uploadTask.isStarted && info.payloadSent == nil {
                activeTasks.append(uploadTask)
                indicesToRemove.append(index)
            }
        }
        
        // Remove extracted tasks from packetsSending (in reverse order to preserve indices)
        for index in indicesToRemove.reversed() {
            self.packetsSending.remove(at: index)
        }
        
        return activeTasks
    }
    
    /// Helper function to validate peer certificate.
    public func shouldTrustPeerCertificate(_ peerCertificate: SecCertificate) -> Bool {
        assert(self.identity != nil, "Identity expected to be known before securing connection")
        
        guard let deviceId = try? self.identity!.getDeviceId() else { return false }
        guard let savedCertificate = self.config.deviceConfig(for: deviceId).certificate else { return false }
        return CertificateUtils.compareCertificates(savedCertificate, peerCertificate)
    }
    
    // MARK: UploadTaskDelegate
    
    public func uploadTask(_ task: UploadTask, finishedWithSuccess payloadSent: Bool) {
        Logger.network.debug("uploadTask finishedWithSuccess:<\(payloadSent, privacy: .public)>")
        
        guard let index = self.packetsSending.firstIndex(where: { $0.uploadTask === task }) else { return }
        
        self.packetsSending[index].payloadSent = payloadSent
        
        if let packetSent = self.packetsSending[index].packetSent {
            let packetInfo = self.packetsSending.remove(at: index)
            self.finalizeSending(packet: packetInfo.dataPacket, completionHandler: packetInfo.completionHandler, packetSent: packetSent, payloadSent: payloadSent)
        }
        
        // If we were waiting to close and no more active uploads, close now
        if self.shouldCloseAfterUploads && !self.hasActiveUploadTasks {
            Logger.network.debug("Connection: all uploads complete, closing now")
            self.channel?.close(mode: .output, promise: nil)
        }
    }
    
    
    // MARK: Pairable
    
    public var pairingStatus: PairingStatus {
        if self.state == .Open {
            return self.pairingHandler!.pairingStatus
        } else {
            return .Unpaired
        }
    }
    
    public func requestPairing() {
        assert(self.state == .Open, "Connection expected to be open")
        let previousStatus = self.pairingHandler!.pairingStatus
        self.pairingHandler!.requestPairing()
        
        // Notify delegate about pairing status change
        let newStatus = self.pairingHandler!.pairingStatus
        if newStatus != previousStatus {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pairingDelegate?.connection(self, pairingStatusChanged: newStatus)
            }
        }
    }
    
    public func acceptPairing() {
        assert(self.state == .Open, "Connection expected to be open")
        self.pairingHandler!.acceptPairing()
        
        // Notify delegate about pairing status change
        // (DefaultPairingHandler.pairingDelegate is nil for Connection, so we handle it here)
        if self.pairingHandler!.pairingStatus == .Paired {
            self.rememberHwAddress()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pairingDelegate?.connection(self, pairingStatusChanged: .Paired)
            }
        }
    }
    
    public func declinePairing() {
        assert(self.state == .Open, "Connection expected to be open")
        self.pairingHandler!.declinePairing()
        
        // Notify delegate about pairing status change
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pairingDelegate?.connection(self, pairingStatusChanged: .Unpaired)
        }
    }
    
    public func unpair() {
        assert(self.state == .Open, "Connection expected to be open")
        self.pairingHandler!.unpair()
        
        // Notify delegate about pairing status change
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pairingDelegate?.connection(self, pairingStatusChanged: .Unpaired)
        }
    }
    
    public func updatePairingStatus(globalStatus: PairingStatus) {
        assert(self.state == .Open, "Connection expected to be open")
        self.pairingHandler!.updatePairingStatus(globalStatus: globalStatus)
    }
    
    // MARK: CustomStringConvertible
    
    public override var description: String {
        let id: String = (try? self.identity?.getDeviceId() ?? "") ?? ""
        let name: String = (try? self.identity?.getDeviceName() ?? "") ?? ""
        return "<Connection:\(self.peerAddress):\(id):\(name)>"
    }
    
    // MARK: Private - Connection Setup
    
    private func connectToAddress(_ address: SocketAddress) {
        let bootstrap = ClientBootstrap(group: self.eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .withTCPKeepalive()
            .channelInitializer { [weak self] channel in
                guard let self = self else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                self.channel = channel
                return self.setupChannelPipeline(channel: channel)
            }
        
        // Convert to NIOCore.SocketAddress
        let targetAddress: NIOCore.SocketAddress
        do {
            let ipString: String
            if address.isIPv4 {
                // address.description for IPv4 is "ip:port", extract just the IP
                let desc = address.description
                ipString = String(desc.split(separator: ":").first ?? "")
            } else if address.isIPv6 {
                // address.description for IPv6 is "[ip]:port", extract just the IP
                let desc = address.description
                if let start = desc.firstIndex(of: "["), let end = desc.firstIndex(of: "]") {
                    ipString = String(desc[desc.index(after: start)..<end])
                } else {
                    Logger.network.error("Failed to parse IPv6 address")
                    return
                }
            } else {
                Logger.network.error("Unsupported address type")
                return
            }
            targetAddress = try NIOCore.SocketAddress(ipAddress: ipString, port: Int(address.port))
        } catch {
            Logger.network.error("Failed to create address: \(error, privacy: .public)")
            return
        }
        
        bootstrap.connect(to: targetAddress).whenComplete { [weak self] result in
            switch result {
            case .success(let channel):
                self?.channel = channel
                Logger.network.debug("Connection connected to \(String(describing: channel.remoteAddress), privacy: .public)")
            case .failure(let error):
                Logger.network.error("Connection failed to connect: \(error, privacy: .public)")
                self?.state = .Closed
            }
        }
    }
    
    @discardableResult
    private func setupChannelPipeline(channel: Channel) -> EventLoopFuture<Void> {
        // Create handlers - wrap decoder/encoder protocols in their handler types
        let decoder = ByteToMessageHandler(KDEConnectPacketDecoder())
        let encoder = MessageToByteHandler(RawDataEncoder())
        self.connectionHandler = ConnectionHandler(connection: self)
        
        // Add handlers to pipeline.
        do {
            try channel.pipeline.syncOperations.addHandler(decoder)
            try channel.pipeline.syncOperations.addHandler(encoder)
            try channel.pipeline.syncOperations.addHandler(self.connectionHandler!)
            return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }
    
    // MARK: Private - TLS
    
    private func performTLSUpgrade(role: TLSRole) {
        guard let channel = self.channel else {
            Logger.network.error("Cannot upgrade to TLS: no channel")
            return
        }
        
        // Determine if this is a paired device
        let isPaired: Bool
        if let deviceId = try? self.identity?.getDeviceId() {
            isPaired = self.config.deviceConfig(for: deviceId).isPaired
        } else {
            isPaired = false
        }
        
        // Create trust handler
        self.trustHandler = TrustHandler(isPaired: isPaired)
        
        channel.eventLoop.execute { [weak self, weak channel] in
            guard let self = self, let channel = channel else { return }
            
            do {
                let sslHandler = try self.createSSLHandler(role: role)
                // Add SSL handler at the front of the pipeline.
                try channel.pipeline.syncOperations.addHandler(sslHandler, position: .first)
            } catch {
                Logger.network.error("Failed to add/create TLS handler: \(error, privacy: .public)")
                self.state = .Closed
            }
        }
    }
    
    private func createSSLHandler(role: TLSRole) throws -> NIOSSLHandler {
        let tlsConfig = try createTLSConfiguration(role: role)
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        
        switch role {
        case .server:
            return NIOSSLServerHandler(
                context: sslContext,
                customVerificationCallback: trustHandler!.verificationCallback
            )
        case .client:
            return try NIOSSLClientHandler(
                context: sslContext,
                serverHostname: nil,
                customVerificationCallback: trustHandler!.verificationCallback
            )
        }
    }
    
    private func createTLSConfiguration(role: TLSRole) throws -> TLSConfiguration {
        // Extract certificate and private key from SecIdentity
        var certificate: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(hostIdentity, &certificate)
        guard certStatus == errSecSuccess, let cert = certificate else {
            throw NIOSSLError.failedToLoadCertificate
        }
        
        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(hostIdentity, &privateKey)
        guard keyStatus == errSecSuccess, let key = privateKey else {
            throw NIOSSLError.failedToLoadPrivateKey
        }
        
        // Convert to NIOSSLCertificate and NIOSSLPrivateKey
        let certData = SecCertificateCopyData(cert) as Data
        let sslCert = try NIOSSLCertificate(bytes: Array(certData), format: .der)
        
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw NIOSSLError.failedToLoadPrivateKey
        }
        
        let sslKey = try NIOSSLPrivateKey(bytes: Array(keyData), format: .der)
        
        var config: TLSConfiguration
        switch role {
        case .server:
            config = TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(sslCert)],
                privateKey: .privateKey(sslKey)
            )
            config.certificateVerification = .noHostnameVerification
        case .client:
            config = TLSConfiguration.makeClientConfiguration()
            config.certificateChain = [.certificate(sslCert)]
            config.privateKey = .privateKey(sslKey)
            config.certificateVerification = .noHostnameVerification
        }
        
        config.minimumTLSVersion = .tlsv12
        return config
    }
    
    // MARK: Private - Packet Handling
    
    fileprivate func handleReceivedData(_ data: Data) {
        guard var mutablePacket = DataPacket(data: data) else {
            Logger.network.error("Could not deserialize received data packet")
            return
        }
        
        if mutablePacket.payloadInfo != nil {
            // Create DownloadTask for packets with payload
            // Extract host IP from peer address
            // IPv4 format: "ip:port", IPv6 format: "[ip]:port"
            let peerHost: String
            let addressDesc = self.peerAddress.description
            if addressDesc.hasPrefix("[") {
                // IPv6: extract between brackets
                if let endBracket = addressDesc.firstIndex(of: "]") {
                    peerHost = String(addressDesc[addressDesc.index(after: addressDesc.startIndex)..<endBracket])
                } else {
                    peerHost = addressDesc
                }
            } else {
                // IPv4: extract before last colon
                if let lastColon = addressDesc.lastIndex(of: ":") {
                    peerHost = String(addressDesc[..<lastColon])
                } else {
                    peerHost = addressDesc
                }
            }
            
            mutablePacket.downloadTask = DownloadTask(
                packet: mutablePacket,
                peerHost: peerHost,
                hostIdentity: self.hostIdentity,
                expectedPeerCertificate: self.peerCertificate,
                eventLoopGroup: self.eventLoopGroup,
                writeQueue: self.downloadQueue,
                delegateQueue: .main
            )
        }
        
        self.handle(packet: mutablePacket)
        
        if self.packetsExpected > 0 {
            self.packetsExpected -= 1
        }
    }
    
    private func handle(packet: DataPacket) {
#if DEBUG
        Logger.network.debug("handle(packet: <\(packet, privacy: .public)>) [\(self, privacy: .public)]")
#else
        Logger.network.debug("handle(packet type: \(packet.type, privacy: .public), id: \(packet.id, privacy: .public)) [\(self, privacy: .public)]")
#endif
        
        // During initialization, pass all packets to delegate (e.g., identity packet)
        // The delegate (ConnectionProvider) will call applyIdentity() and finish initialization
        if self.state == .Initializing {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.connection(self, didReadPacket: packet)
            }
            return
        }
        
        // Handle pairing packets directly
        if packet.isPairingPacket {
            self.handlePairingPacket(packet)
            return
        }
        
        // If not paired (but connection is Open), send unpair notification and don't process further
        if self.pairingStatus != .Paired {
            if self.pairingStatus == .Unpaired {
                _ = self.send(DataPacket.unpairPacket())
            }
            return
        }
        
        // Pass to delegate for external handling
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.connection(self, didReadPacket: packet)
        }
    }
    
    /// Handles pairing packets directly without using ConnectionDataPacketHandler.
    ///
    /// This replaces DefaultPairingHandler.handleDataPacket for Connection.
    private func handlePairingPacket(_ packet: DataPacket) {
        guard let pairingHandler = self.pairingHandler else { return }
        
        do {
            let pairFlag = try packet.getPairFlag()
            if pairFlag {
                switch pairingHandler.pairingStatus {
                case .Unpaired:
                    // Peer initiates pairing - notify delegate with PairingRequest
                    pairingHandler.setStatus(.RequestedByPeer)
                    let request = PairingRequest(connection: self)
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.pairingDelegate?.connection(self, receivedPairingRequest: request)
                    }
                    
                case .Requested:
                    // Peer accepted our request - store certificate and set paired
                    if let deviceId = try? self.identity?.getDeviceId() {
                        let deviceConfig = self.config.deviceConfig(for: deviceId)
                        if deviceConfig.certificate == nil {
                            deviceConfig.certificate = self.peerCertificate
                        }
                    }
                    pairingHandler.setStatus(.Paired)
                    if pairingHandler.pairingStatus != .Paired {
                        _ = self.send(DataPacket.unpairPacket())
                    } else {
                        self.rememberHwAddress()
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self else { return }
                            self.pairingDelegate?.connection(self, pairingStatusChanged: .Paired)
                        }
                    }
                    
                case .Paired:
                    // Already paired - confirm to peer
                    self.acceptPairing()
                    
                case .RequestedByPeer:
                    // Already waiting for response
                    break
                }
            } else {
                // Peer declined or unpaired
                if pairingHandler.pairingStatus == .Requested {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.pairingDelegate?.connection(self, pairingFailed: DefaultPairingHandler.Error.declinedByPeer)
                    }
                }
                pairingHandler.setStatus(.Unpaired)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.pairingDelegate?.connection(self, pairingStatusChanged: .Unpaired)
                }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pairingDelegate?.connection(self, pairingFailed: error)
            }
        }
    }
    
    fileprivate func handleTLSEstablished() {
        self.waitingToSecure = false
        
        // Extract and store peer certificate for pairing
        if let trustHandler = self.trustHandler,
           let peerCert = trustHandler.peerCertificates.first {
            self.peerCertificate = SSLCertificateUtils.createSecCertificate(from: peerCert)
        }
        
        // Perform post-handshake certificate validation for paired devices
        if let trustHandler = self.trustHandler, self.pairingHandler?.pairingStatus == .Paired {
            if let deviceId = try? self.identity?.getDeviceId(),
               let savedCertificate = self.config.deviceConfig(for: deviceId).certificate {
                let validator = PostHandshakeValidator(expectedCertificate: savedCertificate)
                if !validator.validate(peerCertificates: trustHandler.peerCertificates) {
                    Logger.network.error("Post-handshake certificate validation failed - closing connection")
                    self.close()
                    return
                }
            }
        }
        
        if self.shouldFinishIntializationWhenSecured {
            self.state = .Open
        }
    }
    
    fileprivate func handleChannelInactive() {
        self.state = .Closed
        _ = self.discardUnsentPackets(silently: true)
    }
    
    fileprivate func handleWriteComplete(tag: Int) {
        guard let index = self.packetsSending.firstIndex(where: { Int($0.dataPacket.id) == tag }) else { return }
        
        self.packetsSending[index].packetSent = true
        
        if let payloadSent = self.packetsSending[index].payloadSent {
            let packetInfo = self.packetsSending.remove(at: index)
            self.finalizeSending(packet: packetInfo.dataPacket, completionHandler: packetInfo.completionHandler, packetSent: true, payloadSent: payloadSent)
        }
    }
    
    // MARK: Private - Sending
    
    private func sendSimplePacket(_ packet: DataPacket, whenCompleted: SendingCompletionHandler? = nil) -> Bool {
        guard let channel = self.channel else {
            self.finalizeSending(packet: packet, completionHandler: whenCompleted, packetSent: false, payloadSent: false)
            return true
        }
        
#if DEBUG
        Logger.network.debug("send(:\(String(describing: packet), privacy: .public) whenCompleted:\(String(describing: whenCompleted), privacy: .public)) [\(String(describing: self), privacy: .public)]")
#else
        Logger.network.debug("send(type: \(packet.type, privacy: .public), id: \(packet.id, privacy: .public)) [\(String(describing: self), privacy: .public)]")
#endif
        
        guard let bytes = try? packet.serialize() else {
            Logger.network.error("Failed to serialize packet type: \(packet.type, privacy: .public)")
            self.finalizeSending(packet: packet, completionHandler: whenCompleted, packetSent: false, payloadSent: false)
            return true
        }
        
        let data = Data(bytes)
        let info = DataPacketSendingInfo(dataPacket: packet, uploadTask: nil, completionHandler: whenCompleted)
        self.packetsSending.append(info)
        
        // Write Data directly so RawDataEncoder can process it
        channel.writeAndFlush(data).whenComplete { [weak self] result in
            switch result {
            case .success:
                self?.handleWriteComplete(tag: Int(packet.id))
            case .failure(let error):
                Logger.network.error("Failed to write packet: \(error, privacy: .public)")
            }
        }
        
        return true
    }
    
    private func sendPayloadPacket(_ packet: DataPacket, whenCompleted: SendingCompletionHandler? = nil) -> Bool {
        guard self.channel != nil else {
            self.finalizeSending(packet: packet, completionHandler: whenCompleted, packetSent: false, payloadSent: false)
            return true
        }
        
        // Get the peer certificate for verification during payload transfer
        let peerCertificate: SecCertificate?
        if let deviceId = try? self.identity?.getDeviceId() {
            peerCertificate = self.config.deviceConfig(for: deviceId).certificate
        } else {
            peerCertificate = nil
        }
        
        // Create upload task
        guard let uploadTask = UploadTask(
            packet: packet,
            hostIdentity: self.hostIdentity,
            expectedPeerCertificate: peerCertificate,
            eventLoopGroup: self.eventLoopGroup,
            delegateQueue: .main
        ) else {
            Logger.network.error("Failed to create upload task for packet type: \(packet.type, privacy: .public)")
            self.finalizeSending(packet: packet, completionHandler: whenCompleted, packetSent: false, payloadSent: false)
            return true
        }
        
        uploadTask.delegate = self
        
        // Add payload info to the packet
        var payloadPacket = packet
        payloadPacket.payloadInfo = uploadTask.payloadInfo
        
        // Serialize and send the packet
        guard let bytes = try? payloadPacket.serialize() else {
            Logger.network.error("Failed to serialize payload packet type: \(packet.type, privacy: .public)")
            uploadTask.close()
            self.finalizeSending(packet: packet, completionHandler: whenCompleted, packetSent: false, payloadSent: false)
            return true
        }
        
        let data = Data(bytes)
        let info = DataPacketSendingInfo(dataPacket: payloadPacket, uploadTask: uploadTask, completionHandler: whenCompleted)
        self.packetsSending.append(info)
        
        Logger.network.debug("Sending payload packet type: \(packet.type, privacy: .public) with payload on port \(uploadTask.payloadInfo["port"] as? UInt16 ?? 0, privacy: .public)")
        
        self.channel!.writeAndFlush(data).whenComplete { [weak self] result in
            switch result {
            case .success:
                self?.handleWriteComplete(tag: Int(payloadPacket.id))
            case .failure(let error):
                Logger.network.error("Failed to write payload packet: \(error, privacy: .public)")
                uploadTask.close()
            }
        }
        
        return true
    }
    
    private func finalizeSending(packet: DataPacket, completionHandler: SendingCompletionHandler?, packetSent: Bool, payloadSent: Bool) {
        DispatchQueue.main.async { [weak self] in
            completionHandler?(packetSent, payloadSent)
            if packetSent, let self = self {
                self.delegate?.connection(self, didSendPacket: packet, uploadedPayload: payloadSent)
            }
        }
    }
    
    private func sendKeepAlivePacket() {
        let packet = DataPacket(type: "soduto.keepalive", body: [:])
        _ = send(packet)
    }
    
    // MARK: Private - Utilities
    
    private func rememberHwAddress() {
        guard self.pairingStatus == .Paired else { return }
        guard let deviceId = (try? self.identity?.getDeviceId()) ?? nil else { return }
        guard let hwAddress = NetworkUtils.hwAddress(for: self.peerAddress) else { return }
        
        self.config.deviceConfig(for: deviceId).addHwAddress(hwAddress)
    }
    
    private func observeNotifications() {
        NotificationCenter.default.addObserver(forName: PayloadPortRegistry.portReleaseNotification, object: nil, queue: nil) { [weak self] _ in
            if let self = self {
                DispatchQueue.main.async {
                    self.delegate?.connectionCapacityChanged(self)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: ConnectionProvider.networkBecameReachableNotification, object: nil, queue: nil) { [weak self] _ in
            self?.sendKeepAlivePacket()
        }
    }
    
    private func discardUnsentPackets(silently: Bool) -> [(dataPacket: DataPacket, completionHandler: SendingCompletionHandler?)] {
        var results: [(dataPacket: DataPacket, completionHandler: SendingCompletionHandler?)] = []
        for info in self.packetsSending {
            guard info.packetSent == nil && info.uploadTask?.isStarted != true else { continue }
            info.uploadTask?.close()
            if !silently {
                self.finalizeSending(packet: info.dataPacket, completionHandler: info.completionHandler, packetSent: false, payloadSent: false)
            }
            results.append((dataPacket: info.dataPacket, completionHandler: info.completionHandler))
        }
        self.packetsSending = self.packetsSending.filter { $0.packetSent != nil || $0.uploadTask?.isStarted == true }
        return results
    }
    
    private class func createDispatchQueue(withLabel label: String) -> DispatchQueue {
        return DispatchQueue(label: label, qos: .background, autoreleaseFrequency: .workItem)
    }
}

// MARK: - Connection Handler

/// Channel handler for Connection that receives decoded packets.
private final class ConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = Data
    
    private weak var connection: Connection?
    
    init(connection: Connection) {
        self.connection = connection
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packetData = unwrapInboundIn(data)
        connection?.handleReceivedData(packetData)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        connection?.handleChannelInactive()
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent {
            switch tlsEvent {
            case .handshakeCompleted:
                connection?.handleTLSEstablished()
            case .shutdownCompleted:
                break
            }
        }
        context.fireUserInboundEventTriggered(event)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.network.error("Connection error: \(error, privacy: .public)")
        context.close(promise: nil)
    }
}
