//
//  NIODownloadTask.swift
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

/// Delegate protocol for NIODownloadTask events.
public protocol NIODownloadTaskDelegate: AnyObject {
    func nioDownloadTask(_ task: NIODownloadTask, finishedWithSuccess success: Bool)
}

/// NIO-based download task for receiving file payloads over TLS.
///
/// This replaces DownloadTask for NIOConnection, using SwiftNIO ClientBootstrap
/// instead of GCDAsyncSocket. The workflow is:
/// 1. Connect to remote device on specified port
/// 2. Perform TLS handshake as client
/// 3. Receive payload data from the server
/// 4. Write data to the provided OutputStream
/// 5. Close when complete or payload size reached
public class NIODownloadTask {
    
    // MARK: Types
    
    private enum PayloadInfoProperty: String {
        case port = "port"
    }
    
    // MARK: Properties
    
    private static let downloadTimeout: TimeAmount = .seconds(30)
    
    public weak var delegate: NIODownloadTaskDelegate?
    
    public let id: Int64
    public let payloadSize: Int64?
    
    private let payloadPort: UInt16
    private let peerHost: String
    private let hostIdentity: SecIdentity
    private let expectedPeerCertificate: SecCertificate?
    private let eventLoopGroup: EventLoopGroup
    private let writeQueue: DispatchQueue
    private let delegateQueue: DispatchQueue
    
    private var channel: Channel?
    private var stream: OutputStream?
    private var bytesReceived: Int64 = 0
    private var bytesReceivedFromNetwork: Int64 = 0  // Tracked synchronously for completion check
    private var isClosed: Bool = false
    private var trustHandler: NIOPayloadClientTrustHandler?
    
    // MARK: Init / Deinit
    
    /// Creates an NIO download task.
    ///
    /// - Parameters:
    ///   - packet: The data packet containing payload info with port.
    ///   - peerHost: The hostname/IP of the remote device.
    ///   - hostIdentity: The host identity for TLS.
    ///   - expectedPeerCertificate: The certificate to verify server against.
    ///   - eventLoopGroup: The NIO event loop group.
    ///   - writeQueue: Queue for writing to the stream.
    ///   - delegateQueue: Queue for delegate callbacks.
    public init?(
        packet: DataPacket,
        peerHost: String,
        hostIdentity: SecIdentity,
        expectedPeerCertificate: SecCertificate?,
        eventLoopGroup: EventLoopGroup,
        writeQueue: DispatchQueue = .main,
        delegateQueue: DispatchQueue = .main
    ) {
        guard let payloadInfo = packet.payloadInfo else {
            Logger.network.error("NIODownloadTask: packet has no payloadInfo")
            return nil
        }
        
        guard let portNumber = payloadInfo[PayloadInfoProperty.port.rawValue] as? NSNumber else {
            Logger.network.error("NIODownloadTask: payloadInfo missing port")
            return nil
        }
        
        self.id = packet.id
        self.payloadPort = portNumber.uint16Value
        self.payloadSize = packet.payloadSize
        self.peerHost = peerHost
        self.hostIdentity = hostIdentity
        self.expectedPeerCertificate = expectedPeerCertificate
        self.eventLoopGroup = eventLoopGroup
        self.writeQueue = writeQueue
        self.delegateQueue = delegateQueue
        
        Logger.network.debug("NIODownloadTask initialized for port \(self.payloadPort, privacy: .public)")
    }
    
    deinit {
        self.close()
    }
    
    // MARK: Public Methods
    
    /// Starts the download, writing received data to the provided stream.
    ///
    /// - Parameter stream: The output stream to write data to.
    public func start(withStream stream: OutputStream) {
        self.stream = stream
        
        Logger.network.debug("NIODownloadTask starting download from \(self.peerHost, privacy: .public):\(self.payloadPort, privacy: .public)")
        
        do {
            try self.connect()
        } catch {
            Logger.network.error("NIODownloadTask failed to connect: \(error, privacy: .public)")
            self.downloadFinished(success: false)
        }
    }
    
    /// Cancels the download.
    public func cancel() {
        Logger.network.debug("NIODownloadTask cancelled")
        self.channel?.close(promise: nil)
    }
    
    /// Closes the download task and releases resources.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        
        Logger.network.debug("NIODownloadTask close()")
        
        self.delegate = nil
        self.channel?.close(promise: nil)
        self.stream?.close()
    }
    
    // MARK: Private - Connection
    
    private func connect() throws {
        // Create target address with the payload port
        let targetAddress = try NIOCore.SocketAddress(ipAddress: self.peerHost, port: Int(self.payloadPort))
        
        Logger.network.debug("NIODownloadTask connecting to \(String(describing: targetAddress), privacy: .public)")
        
        // Create TLS configuration
        let tlsConfig = try self.createTLSConfiguration()
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        
        // Create and retain trust handler
        self.trustHandler = NIOPayloadClientTrustHandler(expectedCertificate: self.expectedPeerCertificate)
        
        let sslHandler = try NIOSSLClientHandler(
            context: sslContext,
            serverHostname: nil,
            customVerificationCallback: self.trustHandler!.verificationCallback
        )
        
        let downloadHandler = NIODownloadHandler(downloadTask: self)
        
        let bootstrap = ClientBootstrap(group: self.eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: NIODownloadTask.downloadTimeout)
            .withTCPKeepalive()
            .channelInitializer { channel in
                // Add SSL handler first, then our download handler
                channel.pipeline.addHandler(sslHandler).flatMap {
                    channel.pipeline.addHandler(downloadHandler)
                }
            }
        
        // Connect asynchronously
        bootstrap.connect(to: targetAddress).whenComplete { [weak self] result in
            switch result {
            case .success(let channel):
                Logger.network.debug("NIODownloadTask connected successfully")
                self?.channel = channel
            case .failure(let error):
                Logger.network.error("NIODownloadTask connection failed: \(error, privacy: .public)")
                self?.downloadFinished(success: false)
            }
        }
    }
    
    // MARK: Private - TLS
    
    private func createTLSConfiguration() throws -> TLSConfiguration {
        // Extract certificate and private key from SecIdentity
        var certificate: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(hostIdentity, &certificate)
        guard certStatus == errSecSuccess, let cert = certificate else {
            throw NIODownloadTaskError.failedToLoadCertificate
        }
        
        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(hostIdentity, &privateKey)
        guard keyStatus == errSecSuccess, let key = privateKey else {
            throw NIODownloadTaskError.failedToLoadPrivateKey
        }
        
        // Convert to NIOSSLCertificate and NIOSSLPrivateKey
        let certData = SecCertificateCopyData(cert) as Data
        let nioSSLCert = try NIOSSLCertificate(bytes: Array(certData), format: .der)
        
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw NIODownloadTaskError.failedToLoadPrivateKey
        }
        
        let nioSSLKey = try NIOSSLPrivateKey(bytes: Array(keyData), format: .der)
        
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateChain = [.certificate(nioSSLCert)]
        config.privateKey = .privateKey(nioSSLKey)
        
        // For mutual TLS with self-signed certificates:
        // - Use custom verification callback for trust decisions
        config.certificateVerification = .noHostnameVerification
        config.minimumTLSVersion = .tlsv12
        
        return config
    }
    
    // MARK: Private - Data Handling
    
    fileprivate func handleTLSEstablished() {
        Logger.network.debug("NIODownloadTask TLS handshake complete, ready to receive data")
        self.stream?.open()
    }
    
    fileprivate func handleDataReceived(_ data: Data) {
        guard let stream = self.stream, stream.hasSpaceAvailable else {
            Logger.network.error("NIODownloadTask: stream not available for writing")
            self.channel?.close(promise: nil)
            return
        }
        
        // Track bytes received synchronously so channelInactive knows the true count
        self.bytesReceivedFromNetwork += Int64(data.count)
        
        self.writeQueue.async { [weak self] in
            self?.writeData(data: data)
        }
    }
    
    private func writeData(data: Data) {
        guard let stream = self.stream else { return }
        
        var batchBytesWritten = 0
        while stream.hasSpaceAvailable {
            let bytesToWrite: Int
            if let payloadSize = self.payloadSize {
                bytesToWrite = min(data.count - batchBytesWritten, Int(payloadSize - self.bytesReceived))
            } else {
                bytesToWrite = data.count - batchBytesWritten
            }
            guard bytesToWrite > 0 else { break }
            
            let written = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                let ptr = baseAddress.advanced(by: batchBytesWritten)
                return stream.write(ptr.assumingMemoryBound(to: UInt8.self), maxLength: bytesToWrite)
            }
            guard written > 0 else { continue }
            
            batchBytesWritten += written
            self.bytesReceived += Int64(written)
            
            guard batchBytesWritten < data.count else { break }
        }
        
        // Check if we've received all expected data
        if let payloadSize = self.payloadSize, self.bytesReceived >= payloadSize {
            Logger.network.debug("NIODownloadTask received all \(self.bytesReceived, privacy: .public) bytes")
            self.channel?.close(promise: nil)
        }
    }
    
    fileprivate func handleChannelInactive() {
        // Use bytesReceivedFromNetwork (updated synchronously) rather than bytesReceived
        // (updated asynchronously on writeQueue) to avoid race condition where channel
        // closes before async writes complete
        let success: Bool
        if let payloadSize = self.payloadSize {
            success = self.bytesReceivedFromNetwork >= payloadSize
        } else {
            // If no payload size specified, consider it success if we received any data
            success = self.bytesReceivedFromNetwork > 0
        }
        self.downloadFinished(success: success)
    }
    
    fileprivate func handleError(_ error: Error) {
        Logger.network.error("NIODownloadTask error: \(error, privacy: .public)")
        self.downloadFinished(success: false)
    }
    
    private func downloadFinished(success: Bool) {
        guard !isClosed else { return }
        
        Logger.network.debug("NIODownloadTask finished (success: \(success, privacy: .public), bytes: \(self.bytesReceivedFromNetwork, privacy: .public))")
        
        // Capture delegate before close() clears it
        let delegate = self.delegate
        let delegateQueue = self.delegateQueue
        
        // First dispatch to writeQueue to ensure all pending writes complete,
        // then close the stream and notify the delegate
        self.writeQueue.async { [weak self] in
            guard let self = self else { return }
            // Close stream after all writes complete
            self.stream?.close()
            
            delegateQueue.async { [weak self] in
                guard let self = self else { return }
                delegate?.nioDownloadTask(self, finishedWithSuccess: success)
            }
        }
        
        // Close channel and clear delegate, but don't close stream yet (done above on writeQueue)
        self.isClosed = true
        self.delegate = nil
        self.channel?.close(promise: nil)
    }
}

// MARK: - NIODownloadTask Errors

enum NIODownloadTaskError: Error {
    case failedToLoadCertificate
    case failedToLoadPrivateKey
    case trustVerificationFailed
}

// MARK: - NIO Download Handler

/// Channel handler for NIODownloadTask that receives data.
private final class NIODownloadHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    
    private weak var downloadTask: NIODownloadTask?
    
    init(downloadTask: NIODownloadTask) {
        self.downloadTask = downloadTask
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent {
            switch tlsEvent {
            case .handshakeCompleted:
                downloadTask?.handleTLSEstablished()
            case .shutdownCompleted:
                break
            }
        }
        context.fireUserInboundEventTriggered(event)
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        if let data = buffer.readData(length: buffer.readableBytes) {
            downloadTask?.handleDataReceived(data)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        downloadTask?.handleChannelInactive()
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.network.error("NIODownloadTask error: \(error, privacy: .public)")
        downloadTask?.handleError(error)
        context.close(promise: nil)
    }
}

// MARK: - Payload Client Trust Handler

/// Trust handler for download (client) connections.
///
/// Verifies the server certificate matches the expected peer certificate
/// from the main connection.
private final class NIOPayloadClientTrustHandler {
    
    private let expectedCertificate: SecCertificate?
    
    init(expectedCertificate: SecCertificate?) {
        self.expectedCertificate = expectedCertificate
    }
    
    var verificationCallback: NIOSSLCustomVerificationCallback {
        return { [weak self] certificates, promise in
            Logger.network.debug("NIODownloadTask verification callback called with \(certificates.count, privacy: .public) certificate(s)")
            
            guard let expectedCert = self?.expectedCertificate else {
                // No expected certificate - accept (for unpaired mode)
                Logger.network.debug("NIODownloadTask: accepting server (no expected cert)")
                promise.succeed(.certificateVerified)
                return
            }
            
            guard let peerCert = certificates.first else {
                Logger.network.error("NIODownloadTask: no server certificate received")
                promise.fail(NIODownloadTaskError.trustVerificationFailed)
                return
            }
            
            // Compare certificates
            if NIOCertificateUtils.certificatesMatch(peerCert, expectedCert) {
                Logger.network.debug("NIODownloadTask: server certificate verified")
                promise.succeed(.certificateVerified)
            } else {
                Logger.network.error("NIODownloadTask: server certificate mismatch")
                promise.fail(NIODownloadTaskError.trustVerificationFailed)
            }
        }
    }
}
