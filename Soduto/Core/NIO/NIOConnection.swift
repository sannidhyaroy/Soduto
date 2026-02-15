//
//  NIOConnection.swift
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
import CocoaAsyncSocket

// MARK: - Payload Connection Protocol

/// Protocol for connection types that can support payload transfers.
/// Both Connection and NIOConnection conform to this protocol.
public protocol PayloadConnectionProvider: AnyObject {
    /// Secures a server socket for payload transfer.
    func secureServerSocket(_ socket: GCDAsyncSocket)
    
    /// Determines if the peer certificate should be trusted.
    func shouldTrustPeerCertificate(_ peerCertificate: SecCertificate) -> Bool
}

// MARK: - NIOConnection Delegate

/// Delegate protocol for NIOConnection events.
/// This is the NIO equivalent of ConnectionDelegate.
public protocol NIOConnectionDelegate: AnyObject {
    func nioConnection(_ connection: NIOConnection, didSwitchToState state: NIOConnection.State)
    func nioConnection(_ connection: NIOConnection, didSendPacket packet: DataPacket, uploadedPayload: Bool)
    func nioConnection(_ connection: NIOConnection, didReadPacket packet: DataPacket)
    func nioConnectionCapacityChanged(_ connection: NIOConnection)
}

// MARK: - NIO Pairing Request

/// Pairing request for NIOConnection.
/// This is the NIO equivalent of PairingRequest.
public struct NIOPairingRequest {
    public let connection: NIOConnection
}

/// Delegate protocol for NIOConnection pairing events.
/// This is the NIO equivalent of PairableDelegate for use with NIOConnection.
public protocol NIOPairableDelegate: AnyObject {
    func nioConnection(_ connection: NIOConnection, receivedPairingRequest request: NIOPairingRequest)
    func nioConnection(_ connection: NIOConnection, pairingFailed error: Error)
    func nioConnection(_ connection: NIOConnection, pairingStatusChanged status: PairingStatus)
}

// MARK: - NIOConnection

/// SwiftNIO-based implementation of Connection.
///
/// This class provides the same public API as Connection but uses SwiftNIO
/// for networking instead of GCDAsyncSocket. It supports STARTTLS with role
/// reversal as required by KDE Connect protocol.
///
/// Note: This class does not conform to `Pairable` directly because it uses
/// NIO-specific delegate types (`NIOPairableDelegate`). The pairing interface
/// is identical but type-safe for NIO contexts.
public class NIOConnection: NSObject, PayloadConnectionProvider, PairingHandlerDelegate, UploadTaskDelegate {
    
    // MARK: Types
    
    public enum NIOConnectionError: Error {
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
    
    public weak var delegate: NIOConnectionDelegate?
    public weak var pairingDelegate: NIOPairableDelegate?
    
    public private(set) var state: State {
        didSet {
            if oldValue != self.state {
                // Notify delegate on main queue
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.nioConnection(self, didSwitchToState: self.state)
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
    private var trustHandler: NIOTrustHandler?
    
    /// Reference to the packet handler in the pipeline.
    private var connectionHandler: NIOConnectionHandler?
    
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
        self.uploadQueue = NIOConnection.createDispatchQueue(withLabel: "NIO Payload upload queue")
        self.downloadQueue = NIOConnection.createDispatchQueue(withLabel: "NIO Payload download queue")
        
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
        
        // Convert NIO address to legacy SocketAddress
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
        self.uploadQueue = NIOConnection.createDispatchQueue(withLabel: "NIO Payload upload queue")
        self.downloadQueue = NIOConnection.createDispatchQueue(withLabel: "NIO Payload download queue")
        
        super.init()
        
        // Set up the channel pipeline
        self.setupChannelPipeline(channel: channel)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        self.state = .Closed
        self.channel?.close(promise: nil)
    }
    
    // MARK: Public API
    
    public func applyIdentity(packet: DataPacket) throws {
        guard self.state == .Initializing else {
            throw NIOConnectionError.initializationAlreadyFinished
        }
        
        try packet.validateIdentityType()
        let deviceId = try packet.getDeviceId()
        let deviceConfig = self.config.deviceConfig(for: deviceId)
        
        self.identity = packet
        self.pairingHandler = DefaultPairingHandler(config: deviceConfig)
        self.pairingHandler!.delegate = self
        // Note: pairingHandler's pairingDelegate and impersonateAs are NOT set because
        // NIOConnection handles pairing packets directly in handlePairingPacket()
        // and uses NIOPairableDelegate instead of PairableDelegate
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
        self.channel?.close(mode: .output, promise: nil)
    }
    
    /// Helper function to validate peer certificate.
    public func shouldTrustPeerCertificate(_ peerCertificate: SecCertificate) -> Bool {
        assert(self.identity != nil, "Identity expected to be known before securing connection")
        
        guard let deviceId = try? self.identity!.getDeviceId() else { return false }
        guard let savedCertificate = self.config.deviceConfig(for: deviceId).certificate else { return false }
        return CertificateUtils.compareCertificates(savedCertificate, peerCertificate)
    }
    
    /// Secures a server socket for payload transfer (used by UploadTask).
    ///
    /// This allows NIOConnection to work with UploadTask which still uses GCDAsyncSocket
    /// for payload transfers.
    public func secureServerSocket(_ socket: GCDAsyncSocket) {
        let settings: [String: NSObject] = [
            kCFStreamSSLCertificates as String: [self.hostIdentity] as NSArray,
            kCFStreamSSLIsServer as String: NSNumber(value: true),
            GCDAsyncSocketSSLClientSideAuthenticate as String: NSNumber(value: SSLAuthenticate.alwaysAuthenticate.rawValue),
            GCDAsyncSocketManuallyEvaluateTrust as String: NSNumber(value: true)
        ]
        socket.startTLS(settings)
    }
    
    // MARK: UploadTaskDelegate
    
    public func uploadTask(_ task: UploadTask, finishedWithSuccess payloadSent: Bool) {
        Logger.network.debug("uploadTask(<\(task, privacy: .public)> finishedWithSuccess:<\(payloadSent, privacy: .public)>)")
        
        guard let index = self.packetsSending.firstIndex(where: { $0.uploadTask === task }) else { return }
        
        self.packetsSending[index].payloadSent = payloadSent
        
        if let packetSent = self.packetsSending[index].packetSent {
            let packetInfo = self.packetsSending.remove(at: index)
            self.finalizeSending(packet: packetInfo.dataPacket, completionHandler: packetInfo.completionHandler, packetSent: packetSent, payloadSent: payloadSent)
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
        self.pairingHandler!.requestPairing()
    }
    
    public func acceptPairing() {
        assert(self.state == .Open, "Connection expected to be open")
        self.pairingHandler!.acceptPairing()
    }
    
    public func declinePairing() {
        assert(self.state == .Open, "Connection expected to be open")
        self.pairingHandler!.declinePairing()
    }
    
    public func unpair() {
        assert(self.state == .Open, "Connection expected to be open")
        self.pairingHandler!.unpair()
    }
    
    public func updatePairingStatus(globalStatus: PairingStatus) {
        assert(self.state == .Open, "Connection expected to be open")
        self.pairingHandler!.updatePairingStatus(globalStatus: globalStatus)
    }
    
    // MARK: CustomStringConvertible
    
    public override var description: String {
        let id: String = (try? self.identity?.getDeviceId() ?? "") ?? ""
        let name: String = (try? self.identity?.getDeviceName() ?? "") ?? ""
        return "<NIOConnection:\(self.peerAddress):\(id):\(name)>"
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
        
        // Convert legacy SocketAddress to NIO address
        let nioAddress: NIOCore.SocketAddress
        do {
            // Extract IP string from address description and create NIO address
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
            nioAddress = try NIOCore.SocketAddress(ipAddress: ipString, port: Int(address.port))
        } catch {
            Logger.network.error("Failed to create NIO address: \(error, privacy: .public)")
            return
        }
        
        bootstrap.connect(to: nioAddress).whenComplete { [weak self] result in
            switch result {
            case .success(let channel):
                self?.channel = channel
                Logger.network.debug("NIOConnection connected to \(String(describing: channel.remoteAddress), privacy: .public)")
            case .failure(let error):
                Logger.network.error("NIOConnection failed to connect: \(error, privacy: .public)")
                self?.state = .Closed
            }
        }
    }
    
    @discardableResult
    private func setupChannelPipeline(channel: Channel) -> EventLoopFuture<Void> {
        // Create handlers - wrap decoder/encoder protocols in their handler types
        let decoder = ByteToMessageHandler(KDEConnectPacketDecoder())
        let encoder = MessageToByteHandler(RawDataEncoder())
        self.connectionHandler = NIOConnectionHandler(connection: self)
        
        // Add handlers to pipeline
        return channel.pipeline.addHandler(decoder).flatMap {
            channel.pipeline.addHandler(encoder)
        }.flatMap {
            channel.pipeline.addHandler(self.connectionHandler!)
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
        self.trustHandler = NIOTrustHandler(isPaired: isPaired)
        
        do {
            let sslHandler = try self.createSSLHandler(role: role)
            
            // Add SSL handler at the front of the pipeline
            channel.pipeline.addHandler(sslHandler, position: .first).whenComplete { [weak self] result in
                switch result {
                case .success:
                    Logger.network.debug("TLS handler added as \(role == .server ? "server" : "client", privacy: .public)")
                case .failure(let error):
                    Logger.network.error("Failed to add TLS handler: \(error, privacy: .public)")
                    self?.state = .Closed
                }
            }
        } catch {
            Logger.network.error("Failed to create SSL handler: \(error, privacy: .public)")
            self.state = .Closed
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
        let nioSSLCert = try NIOSSLCertificate(bytes: Array(certData), format: .der)
        
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw NIOSSLError.failedToLoadPrivateKey
        }
        
        let nioSSLKey = try NIOSSLPrivateKey(bytes: Array(keyData), format: .der)
        
        var config: TLSConfiguration
        switch role {
        case .server:
            config = TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(nioSSLCert)],
                privateKey: .privateKey(nioSSLKey)
            )
            config.certificateVerification = .noHostnameVerification
        case .client:
            config = TLSConfiguration.makeClientConfiguration()
            config.certificateChain = [.certificate(nioSSLCert)]
            config.privateKey = .privateKey(nioSSLKey)
            config.certificateVerification = .noHostnameVerification
        }
        
        config.minimumTLSVersion = .tlsv12
        return config
    }
    
    // MARK: Private - Packet Handling
    
    fileprivate func handleReceivedData(_ data: Data) {
        guard let packet = DataPacket(data: data) else {
            Logger.network.error("Could not deserialize received data packet")
            return
        }
        
        if packet.payloadInfo != nil {
            // TODO: DownloadTask integration requires Connection type
            // For now, payload downloads are not supported with NIOConnection
            // This will be addressed when DownloadTask is migrated to support NIOConnection
            Logger.network.debug("Packet has payload but NIOConnection doesn't support DownloadTask yet")
        }
        
        self.handle(packet: packet)
        
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
        
        // Handle pairing packets directly
        if packet.isPairingPacket {
            self.handlePairingPacket(packet)
            return
        }
        
        // If not paired, send unpair notification and don't process further
        if self.pairingStatus != .Paired {
            if self.pairingStatus == .Unpaired {
                _ = self.send(DataPacket.unpairPacket())
            }
            return
        }
        
        // Pass to delegate for external handling
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.nioConnection(self, didReadPacket: packet)
        }
    }
    
    /// Handles pairing packets directly without using ConnectionDataPacketHandler.
    ///
    /// This replaces DefaultPairingHandler.handleDataPacket for NIOConnection,
    /// adapting the pairing logic to work with NIO-specific types.
    private func handlePairingPacket(_ packet: DataPacket) {
        guard let pairingHandler = self.pairingHandler else { return }
        
        do {
            let pairFlag = try packet.getPairFlag()
            if pairFlag {
                switch pairingHandler.pairingStatus {
                case .Unpaired:
                    // Peer initiates pairing - notify delegate with NIOPairingRequest
                    pairingHandler.updatePairingStatus(globalStatus: .RequestedByPeer)
                    let request = NIOPairingRequest(connection: self)
                    self.pairingDelegate?.nioConnection(self, receivedPairingRequest: request)
                    
                case .Requested:
                    // Peer accepted our request - store certificate and set paired
                    if let deviceId = try? self.identity?.getDeviceId() {
                        let deviceConfig = self.config.deviceConfig(for: deviceId)
                        if deviceConfig.certificate == nil {
                            deviceConfig.certificate = self.peerCertificate
                        }
                    }
                    pairingHandler.updatePairingStatus(globalStatus: .Paired)
                    if pairingHandler.pairingStatus != .Paired {
                        _ = self.send(DataPacket.unpairPacket())
                    } else {
                        self.pairingDelegate?.nioConnection(self, pairingStatusChanged: .Paired)
                        self.rememberHwAddress()
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
                    self.pairingDelegate?.nioConnection(self, pairingFailed: DefaultPairingHandler.Error.declinedByPeer)
                }
                pairingHandler.updatePairingStatus(globalStatus: .Unpaired)
                self.pairingDelegate?.nioConnection(self, pairingStatusChanged: .Unpaired)
            }
        } catch {
            self.pairingDelegate?.nioConnection(self, pairingFailed: error)
        }
    }
    
    fileprivate func handleTLSEstablished() {
        Logger.network.debug("TLS handshake completed")
        self.waitingToSecure = false
        
        // Perform post-handshake certificate validation
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
        
        // Store peer certificate for later use
        // Note: We can't easily extract SecCertificate from NIOSSLCertificate
        // The peer certificate validation is done via PostHandshakeValidator
        
        if self.shouldFinishIntializationWhenSecured {
            self.state = .Open
        }
    }
    
    fileprivate func handleChannelInactive() {
        Logger.network.debug("NIOConnection channel closed")
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
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        
        let info = DataPacketSendingInfo(dataPacket: packet, uploadTask: nil, completionHandler: whenCompleted)
        self.packetsSending.append(info)
        
        channel.writeAndFlush(buffer).whenComplete { [weak self] result in
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
        
        // TODO: UploadTask integration requires Connection type
        // For now, payload uploads are not supported with NIOConnection
        // This will be addressed when UploadTask is migrated to support NIOConnection
        Logger.network.error("NIOConnection doesn't support payload uploads yet - packet type: \(packet.type, privacy: .public)")
        self.finalizeSending(packet: packet, completionHandler: whenCompleted, packetSent: false, payloadSent: false)
        return true
    }
    
    private func finalizeSending(packet: DataPacket, completionHandler: SendingCompletionHandler?, packetSent: Bool, payloadSent: Bool) {
        DispatchQueue.main.async { [weak self] in
            completionHandler?(packetSent, payloadSent)
            if packetSent, let self = self {
                self.delegate?.nioConnection(self, didSendPacket: packet, uploadedPayload: payloadSent)
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
        NotificationCenter.default.addObserver(forName: UploadTask.portReleaseNotification, object: nil, queue: nil) { [weak self] _ in
            if let self = self {
                DispatchQueue.main.async {
                    self.delegate?.nioConnectionCapacityChanged(self)
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

// MARK: - NIO Connection Handler

/// Channel handler for NIOConnection that receives decoded packets.
private final class NIOConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = Data
    
    private weak var connection: NIOConnection?
    
    init(connection: NIOConnection) {
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
        Logger.network.error("NIOConnection error: \(error, privacy: .public)")
        context.close(promise: nil)
    }
}
