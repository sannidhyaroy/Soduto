//
//  DownloadTask.swift
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

/// Delegate protocol for DownloadTask events.
public protocol DownloadTaskDelegate: AnyObject {
    func downloadTask(_ task: DownloadTask, finishedWithSuccess success: Bool)
}

/// Download task for receiving file payloads over TLS.
///
/// Uses SwiftNIO's ClientBootstrap. The workflow is:
/// 1. Connect to remote device on specified port
/// 2. Perform TLS handshake as client
/// 3. Receive payload data from the server
/// 4. Write data to the provided OutputStream
/// 5. Close when complete or payload size reached
///
/// ## Buffer Strategy
///
/// The legacy DownloadTask used an explicit 32MB buffer citing "SSD optimization" from a
/// 2014 article. However, that recommendation was about SSD erase block sizes at the
/// hardware level, not socket buffer sizes.
///
/// This implementation uses NIO's adaptive receive buffer allocator instead. Research shows:
/// - For TCP socket reads, 32KB-64KB achieves ~95% of maximum throughput
/// - Beyond 256KB, performance gains are minimal and can decrease due to CPU cache effects
/// - macOS kernel, APFS, and NVMe firmware handle SSD write optimization transparently
///
/// Modern systems (macOS 14+, Apple Silicon NVMe) handle SSD optimization at lower layers
/// automatically, so explicit large buffers are unnecessary.
///
/// - SeeAlso: https://www.evanjones.ca/read-write-buffer-size.html
/// - SeeAlso: http://codecapsule.com/2014/02/12/coding-for-ssds-part-6-a-summary-what-every-programmer-should-know-about-solid-state-drives/
public class DownloadTask {
    
    // MARK: Types
    
    private enum PayloadInfoProperty: String {
        case port = "port"
    }
    
    // MARK: Properties
    
    private static let downloadTimeout: TimeAmount = .seconds(30)
    
    public weak var delegate: DownloadTaskDelegate?
    
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
    private var trustHandler: PayloadClientTrustHandler?
    
    // MARK: Init / Deinit
    
    /// Creates a download task.
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
            Logger.network.error("DownloadTask: packet has no payloadInfo")
            return nil
        }
        
        guard let portNumber = payloadInfo[PayloadInfoProperty.port.rawValue] as? NSNumber else {
            Logger.network.error("DownloadTask: payloadInfo missing port")
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
        
        do {
            try self.connect()
        } catch {
            Logger.network.error("DownloadTask failed to connect: \(error, privacy: .public)")
            self.downloadFinished(success: false)
        }
    }
    
    /// Cancels the download.
    public func cancel() {
        self.channel?.close(promise: nil)
    }
    
    /// Closes the download task and releases resources.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        
        self.delegate = nil
        self.channel?.close(promise: nil)
        self.stream?.close()
    }
    
    // MARK: Private - Connection
    
    private func connect() throws {
        // Create target address with the payload port
        let targetAddress = try NIOCore.SocketAddress(ipAddress: self.peerHost, port: Int(self.payloadPort))
        
        // Create TLS configuration
        let tlsConfig = try self.createTLSConfiguration()
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        
        // Create and retain trust handler
        self.trustHandler = PayloadClientTrustHandler(expectedCertificate: self.expectedPeerCertificate)
        
        let bootstrap = ClientBootstrap(group: self.eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: DownloadTask.downloadTimeout)
            .withTCPKeepalive()
            .channelInitializer { channel in
                do {
                    let sslHandler = try NIOSSLClientHandler(
                        context: sslContext,
                        serverHostname: nil,
                        customVerificationCallback: self.trustHandler!.verificationCallback
                    )
                    let downloadHandler = DownloadHandler(downloadTask: self)
                    // Add SSL handler first, then our download handler
                    try channel.pipeline.syncOperations.addHandler(sslHandler)
                    try channel.pipeline.syncOperations.addHandler(downloadHandler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        
        // Connect asynchronously
        bootstrap.connect(to: targetAddress).whenComplete { [weak self] result in
            switch result {
            case .success(let channel):
                self?.channel = channel
            case .failure(let error):
                Logger.network.error("DownloadTask connection failed: \(error, privacy: .public)")
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
            throw DownloadTaskError.failedToLoadCertificate
        }
        
        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(hostIdentity, &privateKey)
        guard keyStatus == errSecSuccess, let key = privateKey else {
            throw DownloadTaskError.failedToLoadPrivateKey
        }
        
        // Convert to NIOSSLCertificate and NIOSSLPrivateKey
        let certData = SecCertificateCopyData(cert) as Data
        let sslCert = try NIOSSLCertificate(bytes: Array(certData), format: .der)
        
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw DownloadTaskError.failedToLoadPrivateKey
        }
        
        let sslKey = try NIOSSLPrivateKey(bytes: Array(keyData), format: .der)
        
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateChain = [.certificate(sslCert)]
        config.privateKey = .privateKey(sslKey)
        
        // For mutual TLS with self-signed certificates:
        // - Use custom verification callback for trust decisions
        config.certificateVerification = .noHostnameVerification
        config.minimumTLSVersion = .tlsv12
        
        return config
    }
    
    // MARK: Private - Data Handling
    
    fileprivate func handleTLSEstablished() {
        self.stream?.open()
    }
    
    fileprivate func handleDataReceived(_ data: Data) {
        guard let stream = self.stream, stream.hasSpaceAvailable else {
            Logger.network.error("DownloadTask: stream not available for writing")
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
        Logger.network.error("DownloadTask error: \(error, privacy: .public)")
        self.downloadFinished(success: false)
    }
    
    private func downloadFinished(success: Bool) {
        guard !isClosed else { return }
        
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
                delegate?.downloadTask(self, finishedWithSuccess: success)
            }
        }
        
        // Close channel and clear delegate, but don't close stream yet (done above on writeQueue)
        self.isClosed = true
        self.delegate = nil
        self.channel?.close(promise: nil)
    }
}

// MARK: - DownloadTask Errors

enum DownloadTaskError: Error {
    case failedToLoadCertificate
    case failedToLoadPrivateKey
    case trustVerificationFailed
}

// MARK: - Download Handler

/// Channel handler for DownloadTask that receives data.
private final class DownloadHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    
    private weak var downloadTask: DownloadTask?
    
    init(downloadTask: DownloadTask) {
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
        Logger.network.error("DownloadTask error: \(error, privacy: .public)")
        downloadTask?.handleError(error)
        context.close(promise: nil)
    }
}

// MARK: - Payload Client Trust Handler

/// Trust handler for download (client) connections.
///
/// Verifies the server certificate matches the expected peer certificate
/// from the main connection.
private final class PayloadClientTrustHandler {
    
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
                Logger.network.error("DownloadTask: no server certificate received")
                promise.fail(DownloadTaskError.trustVerificationFailed)
                return
            }
            
            // Compare certificates
            if SSLCertificateUtils.certificatesMatch(peerCert, expectedCert) {
                promise.succeed(.certificateVerified)
            } else {
                Logger.network.error("DownloadTask: server certificate mismatch")
                promise.fail(DownloadTaskError.trustVerificationFailed)
            }
        }
    }
}
