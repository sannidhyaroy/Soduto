//
//  UploadTask.swift
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

/// Delegate protocol for UploadTask events.
public protocol UploadTaskDelegate: AnyObject {
    func uploadTask(_ task: UploadTask, finishedWithSuccess success: Bool)
}

/// Upload task for serving file payloads over TLS.
///
/// Uses SwiftNIO's ServerBootstrap. The workflow is:
/// 1. Bind to an available port in range 1739-1764
/// 2. Accept a single incoming connection
/// 3. Perform TLS handshake as server with client authentication
/// 4. Stream the payload data to the connected client
/// 5. Close the connection when complete
///
/// ## Buffer Strategy
///
/// The legacy UploadTask used a 32MB buffer citing "SSD optimization" from a 2014 article.
/// However, that recommendation was about SSD erase block sizes at the hardware level,
/// not socket/file buffer sizes.
///
/// This implementation uses a 1MB buffer based on research:
/// - For socket writes, 256KB-1MB achieves optimal throughput
/// - For large file reads (100+ MB), 512KB-1MB is optimal per .NET FileStream benchmarks
/// - Unlike DownloadTask, we cannot use NIO's adaptive allocator here because
///   InputStream.read() requires a pre-allocated buffer (pull-based API)
///
/// Modern macOS (APFS, NVMe firmware) handles SSD optimization at lower layers.
///
/// - SeeAlso: https://www.evanjones.ca/read-write-buffer-size.html
/// - SeeAlso: https://github.com/dotnet/runtime/discussions/74405
public class UploadTask {
    
    // MARK: Types
    
    private enum PayloadInfoProperty: String {
        case port = "port"
    }
    
    // MARK: Properties
    
    public static let portReleaseNotification: Notification.Name = PayloadPortRegistry.portReleaseNotification
    
    public weak var delegate: UploadTaskDelegate?
    
    public var payloadInfo: DataPacket.PayloadInfo {
        return [PayloadInfoProperty.port.rawValue: self.listeningPort as AnyObject]
    }
    
    public var isStarted: Bool { return self.uploadChannel != nil }
    
    private static let startPort: UInt16 = 1739
    private static let endPort: UInt16 = 1764
    private static let maxBufferSize = 1024 * 1024 // 1MB - optimal for socket writes
    private static let uploadTimeout: TimeAmount = .seconds(30)
    private static let listenTimeout: TimeAmount = .seconds(30)
    
    private let hostIdentity: SecIdentity
    private let payload: InputStream
    private let payloadSize: Int64?
    private let eventLoopGroup: EventLoopGroup
    private let delegateQueue: DispatchQueue
    private let expectedPeerCertificate: SecCertificate?
    
    private var serverChannel: Channel?
    private var uploadChannel: Channel?
    private var listeningPort: UInt16 = 0
    private var bytesSent: Int64 = 0
    private var readBuffer = [UInt8](repeating: 0, count: UploadTask.maxBufferSize)
    private var listenTimeoutTask: Scheduled<Void>?
    private var isClosed: Bool = false
    private var trustHandler: PayloadTrustHandler?
    
    // MARK: Init / Deinit
    
    /// Creates an upload task.
    ///
    /// - Parameters:
    ///   - packet: The data packet with payload to serve.
    ///   - hostIdentity: The host identity for TLS.
    ///   - expectedPeerCertificate: Optional certificate to verify client against.
    ///   - eventLoopGroup: The NIO event loop group.
    ///   - delegateQueue: Queue for delegate callbacks.
    public init?(
        packet: DataPacket,
        hostIdentity: SecIdentity,
        expectedPeerCertificate: SecCertificate?,
        eventLoopGroup: EventLoopGroup,
        delegateQueue: DispatchQueue = .main
    ) {
        guard packet.hasPayload() else {
            Logger.network.error("UploadTask: packet has no payload")
            return nil
        }
        guard let payload = packet.payload else {
            Logger.network.error("UploadTask: packet payload is nil")
            return nil
        }
        
        self.hostIdentity = hostIdentity
        self.payload = payload
        self.payloadSize = packet.payloadSize
        self.eventLoopGroup = eventLoopGroup
        self.delegateQueue = delegateQueue
        self.expectedPeerCertificate = expectedPeerCertificate
        
        // Find and bind to an available port
        guard self.bindToAvailablePort() else {
            Logger.network.error("UploadTask: no available port")
            return nil
        }
        
        Logger.network.debug("Providing payload on port \(self.listeningPort, privacy: .public)")
    }
    
    deinit {
        self.close()
    }
    
    // MARK: Public Methods
    
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        
        Logger.network.debug("UploadTask closing on port \(self.listeningPort, privacy: .public)")
        
        self.delegate = nil
        self.listenTimeoutTask?.cancel()
        self.serverChannel?.close(promise: nil)
        self.uploadChannel?.close(promise: nil)
        self.payload.close()
    }
    
    // MARK: Private - Server Setup
    
    private func bindToAvailablePort() -> Bool {
        for port in UploadTask.startPort...UploadTask.endPort {
            guard !PayloadPortRegistry.isPortUsed(port) else { continue }
            
            do {
                try self.startServer(on: port)
                self.listeningPort = port
                PayloadPortRegistry.usePort(port)
                return true
            } catch {
                // Port binding failed, try next port
                continue
            }
        }
        return false
    }
    
    private func startServer(on port: UInt16) throws {
        let bootstrap = ServerBootstrap(group: self.eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 1)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .serverChannelInitializer { channel in
                // Add error handler for the server channel
                channel.pipeline.addHandler(ServerErrorHandler())
            }
            .childChannelInitializer { [weak self] channel in
                guard let self = self else {
                    return channel.eventLoop.makeFailedFuture(UploadTaskError.taskDeallocated)
                }
                return self.setupClientChannel(channel)
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: true)
            .withChildTCPKeepalive()
        
        // Bind to the port - use a dispatch queue to avoid blocking event loop
        let semaphore = DispatchSemaphore(value: 0)
        var bindResult: Result<Channel, Error>?
        
        DispatchQueue.global().async {
            do {
                let channel = try bootstrap.bind(host: "0.0.0.0", port: Int(port)).wait()
                bindResult = .success(channel)
            } catch {
                bindResult = .failure(error)
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        
        switch bindResult {
        case .success(let channel):
            self.serverChannel = channel
        case .failure(let error):
            throw error
        case .none:
            throw UploadTaskError.taskDeallocated
        }
        
        // Set up listen timeout on the server channel's event loop
        let eventLoop = self.serverChannel!.eventLoop
        self.listenTimeoutTask = eventLoop.scheduleTask(in: UploadTask.listenTimeout) { [weak self] in
            guard let self = self, self.uploadChannel == nil else { return }
            Logger.network.info("UploadTask listen timeout on port \(self.listeningPort, privacy: .public)")
            self.uploadFinished(success: false)
        }
    }
    
    private func setupClientChannel(_ channel: Channel) -> EventLoopFuture<Void> {
        // Cancel listen timeout since we got a connection
        self.listenTimeoutTask?.cancel()
        self.listenTimeoutTask = nil
        
        // Only accept one connection
        guard self.uploadChannel == nil else {
            return channel.close()
        }
        
        self.uploadChannel = channel
        
        // Set up handlers - add SSL handler dynamically after channel is active
        // Note: We cannot close the server channel here as it causes the child channel to close
        do {
            // Create SSL handler but don't add it yet - it will be inserted on channelActive
            let sslHandler = try self.createSSLHandler()
            
            // SSLInserterHandler will insert SSL at front of pipeline when channel becomes active
            let sslInserter = SSLInserterHandler(sslHandler: sslHandler, serverChannel: self.serverChannel)
            let uploadHandler = UploadHandler(uploadTask: self)
            
            try channel.pipeline.syncOperations.addHandler(sslInserter)
            try channel.pipeline.syncOperations.addHandler(uploadHandler)
            
            return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
            Logger.network.error("UploadTask failed to set up pipeline: \(error, privacy: .public)")
            return channel.eventLoop.makeFailedFuture(error)
        }
    }
    
    // MARK: Private - TLS
    
    private func createSSLHandler() throws -> NIOSSLServerHandler {
        let tlsConfig = try self.createTLSConfiguration()
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        
        // Create and retain trust handler for client certificate verification
        self.trustHandler = PayloadTrustHandler(expectedCertificate: self.expectedPeerCertificate)
        
        let handler = NIOSSLServerHandler(
            context: sslContext,
            customVerificationCallback: self.trustHandler!.verificationCallback
        )
        return handler
    }
    
    private func createTLSConfiguration() throws -> TLSConfiguration {
        // Extract certificate and private key from SecIdentity
        var certificate: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(hostIdentity, &certificate)
        guard certStatus == errSecSuccess, let cert = certificate else {
            throw UploadTaskError.failedToLoadCertificate
        }
        
        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(hostIdentity, &privateKey)
        guard keyStatus == errSecSuccess, let key = privateKey else {
            throw UploadTaskError.failedToLoadPrivateKey
        }
        
        // Convert to NIOSSLCertificate and NIOSSLPrivateKey
        let certData = SecCertificateCopyData(cert) as Data
        let sslCert = try NIOSSLCertificate(bytes: Array(certData), format: .der)
        
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw UploadTaskError.failedToLoadPrivateKey
        }
        
        let sslKey = try NIOSSLPrivateKey(bytes: Array(keyData), format: .der)
        
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(sslCert)],
            privateKey: .privateKey(sslKey)
        )
        
        // For mutual TLS with self-signed certificates:
        // - Request client certificate (.noHostnameVerification triggers SSL_VERIFY_PEER)
        // - Use custom verification callback for trust decisions
        config.certificateVerification = .noHostnameVerification
        config.minimumTLSVersion = .tlsv12
        
        return config
    }
    
    // MARK: Private - Data Transfer
    
    fileprivate func handleTLSEstablished(context: ChannelHandlerContext) {
        self.payload.open()
        self.sendNextChunk(context: context)
    }
    
    fileprivate func handleWriteComplete(context: ChannelHandlerContext) {
        self.sendNextChunk(context: context)
    }
    
    private func sendNextChunk(context: ChannelHandlerContext) {
        guard self.payload.hasBytesAvailable else {
            // All data sent
            context.close(promise: nil)
            return
        }
        
        let bytesToRead: Int
        if let payloadSize = self.payloadSize {
            bytesToRead = min(Int(payloadSize - self.bytesSent), UploadTask.maxBufferSize)
        } else {
            bytesToRead = UploadTask.maxBufferSize
        }
        
        guard bytesToRead > 0 else {
            context.close(promise: nil)
            return
        }
        
        let read = self.payload.read(&self.readBuffer, maxLength: bytesToRead)
        guard read > 0 else {
            if read < 0 {
                Logger.network.error("UploadTask: stream read error (streamError=\(String(describing: self.payload.streamError), privacy: .public))")
            }
            context.close(promise: nil)
            return
        }
        
        var buffer = context.channel.allocator.buffer(capacity: read)
        buffer.writeBytes(self.readBuffer[0..<read])
        
        self.bytesSent += Int64(read)
        
        context.writeAndFlush(NIOAny(buffer)).whenComplete { [weak self] result in
            switch result {
            case .success:
                // Continue sending on the event loop
                context.eventLoop.execute {
                    self?.handleWriteComplete(context: context)
                }
            case .failure(let error):
                Logger.network.error("UploadTask write error: \(error, privacy: .public)")
                context.close(promise: nil)
            }
        }
    }
    
    fileprivate func handleChannelInactive() {
        let success = self.payloadSize == nil || self.bytesSent >= self.payloadSize!
        self.uploadFinished(success: success)
    }
    
    fileprivate func handleError(_ error: Error) {
        Logger.network.error("UploadTask error: \(error, privacy: .public)")
        self.uploadFinished(success: false)
    }
    
    private func uploadFinished(success: Bool) {
        guard !isClosed else { return }
        
        Logger.network.debug("uploadFinished(<\(success, privacy: .public)>)")
        
        PayloadPortRegistry.releasePort(self.listeningPort)
        
        // Capture delegate before close() clears it
        let delegate = self.delegate
        
        self.delegateQueue.async { [weak self] in
            guard let self = self else { return }
            delegate?.uploadTask(self, finishedWithSuccess: success)
        }
        
        self.close()
    }
}

// MARK: - UploadTask Errors

enum UploadTaskError: Error {
    case taskDeallocated
    case failedToLoadCertificate
    case failedToLoadPrivateKey
    case trustVerificationFailed
}

// MARK: - Server Error Handler

/// Error handler for the server channel (accepts connections).
private final class ServerErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Channel
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.network.error("UploadTask server error: \(error, privacy: .public)")
        context.close(promise: nil)
    }
}

// MARK: - SSL Inserter Handler

/// Handler that inserts the SSL handler when the channel becomes active.
///
/// TLS is started after the connection is established (STARTTLS pattern).
/// We cannot add the SSL handler during childChannelInitializer because closing the server channel
/// at that point causes the child channel to close before becoming active.
private final class SSLInserterHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    
    private let sslHandler: NIOSSLServerHandler
    private var serverChannel: Channel?
    private var inserted = false
    
    init(sslHandler: NIOSSLServerHandler, serverChannel: Channel?) {
        self.sslHandler = sslHandler
        self.serverChannel = serverChannel
    }
    
    func channelActive(context: ChannelHandlerContext) {
        guard !inserted else {
            context.fireChannelActive()
            return
        }
        inserted = true
        
        do {
            // Insert SSL handler at the front of the pipeline
            try context.pipeline.syncOperations.addHandler(sslHandler, position: .first)
            // Now safe to close the server channel
            self.serverChannel?.close(promise: nil)
            self.serverChannel = nil
            // Remove ourselves from the pipeline
            _ = context.pipeline.syncOperations.removeHandler(context: context)
            // Fire channelActive to downstream handlers
            context.fireChannelActive()
        } catch {
            Logger.network.error("UploadTask: failed to insert SSL handler: \(error, privacy: .public)")
            context.close(promise: nil)
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.network.error("UploadTask SSL inserter error: \(error, privacy: .public)")
        context.fireErrorCaught(error)
    }
}

// MARK: - Upload Handler

/// Channel handler for UploadTask that manages the data transfer.
private final class UploadHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    
    private weak var uploadTask: UploadTask?
    
    init(uploadTask: UploadTask) {
        self.uploadTask = uploadTask
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent {
            switch tlsEvent {
            case .handshakeCompleted:
                uploadTask?.handleTLSEstablished(context: context)
            case .shutdownCompleted:
                break
            }
        }
        context.fireUserInboundEventTriggered(event)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        uploadTask?.handleChannelInactive()
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.network.error("UploadTask error: \(error, privacy: .public)")
        uploadTask?.handleError(error)
        context.close(promise: nil)
    }
}

// MARK: - Payload Trust Handler

/// Trust handler for payload transfer connections.
///
/// For payload transfers, we verify the client certificate matches the
/// expected peer certificate from the main connection.
private final class PayloadTrustHandler {
    
    private let expectedCertificate: SecCertificate?
    
    init(expectedCertificate: SecCertificate?) {
        self.expectedCertificate = expectedCertificate
    }
    
    var verificationCallback: NIOSSLCustomVerificationCallback {
        return { [weak self] certificates, promise in
            guard let expectedCert = self?.expectedCertificate else {
                // No expected certificate - accept (for unpaired mode)
                promise.succeed(.certificateVerified)
                return
            }
            
            guard let peerCert = certificates.first else {
                Logger.network.error("UploadTask: no client certificate received")
                promise.fail(UploadTaskError.trustVerificationFailed)
                return
            }
            
            // Compare certificates
            if SSLCertificateUtils.certificatesMatch(peerCert, expectedCert) {
                promise.succeed(.certificateVerified)
            } else {
                Logger.network.error("UploadTask: client certificate mismatch")
                promise.fail(UploadTaskError.trustVerificationFailed)
            }
        }
    }
}
