//
//  STARTTLSHandler.swift
//  Soduto
//
//  Created by Sannidhya Roy on 15/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import NIOCore
import NIOSSL
import NIOTLS
import os

/// TLS role for STARTTLS upgrade.
///
/// KDE Connect uses role reversal:
/// - Connection **initiator** becomes TLS **server**
/// - Connection **acceptor** becomes TLS **client**
enum TLSRole {
    case server
    case client
}

/// Errors that can occur during STARTTLS upgrade.
enum STARTTLSError: Error {
    case handlerNotInPipeline
    case upgradeAlreadyInProgress
    case channelNotAvailable
}

/// Handler that coordinates STARTTLS upgrade on an established plain-text connection.
///
/// KDE Connect protocol flow:
/// 1. TCP connection established (plain text)
/// 2. Identity packets exchanged (plain text JSON)
/// 3. STARTTLS upgrade triggered (this handler)
/// 4. TLS handshake with role reversal
/// 5. Subsequent packets are encrypted
///
/// This handler dynamically adds the appropriate NIOSSLHandler to the pipeline
/// when `upgradeToTLS()` is called, enabling mid-connection TLS upgrade.
final class STARTTLSHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    /// Callback invoked when TLS handshake completes successfully.
    typealias TLSCompletionHandler = (Result<Void, Error>) -> Void
    
    private let identity: SecIdentity
    private let trustHandler: NIOTrustHandler
    private var upgradePromise: EventLoopPromise<Void>?
    private weak var channel: Channel?
    
    /// Creates a STARTTLS handler with the given host identity and trust handler.
    ///
    /// - Parameters:
    ///   - identity: The host's SecIdentity (certificate + private key) to present during TLS handshake.
    ///   - trustHandler: Handler for custom certificate verification.
    init(identity: SecIdentity, trustHandler: NIOTrustHandler) {
        self.identity = identity
        self.trustHandler = trustHandler
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        self.channel = context.channel
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Pass through - this handler doesn't modify data
        context.fireChannelRead(data)
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // Pass through - this handler doesn't modify data
        context.write(data, promise: promise)
    }
    
    /// Upgrades the connection to TLS.
    ///
    /// This method dynamically adds an NIOSSLHandler to the front of the pipeline,
    /// enabling encryption for all subsequent traffic.
    ///
    /// - Parameters:
    ///   - role: Whether to act as TLS server or client.
    ///   - context: The channel handler context.
    /// - Returns: A future that completes when the TLS handshake finishes.
    func upgradeToTLS(role: TLSRole, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        let promise = context.eventLoop.makePromise(of: Void.self)
        self.upgradePromise = promise
        
        do {
            let sslHandler = try createSSLHandler(role: role)
            
            // Add SSL handler at the front of the pipeline (before all other handlers)
            // This ensures all traffic is encrypted/decrypted at the lowest level
            context.pipeline.addHandler(sslHandler, position: .first).whenComplete { [weak self] result in
                switch result {
                case .success:
                    // The promise will be fulfilled when handshake completes via userInboundEventTriggered
                    break
                case .failure(let error):
                    Logger.network.error("Failed to add TLS handler: \(error, privacy: .public)")
                    self?.upgradePromise?.fail(error)
                }
            }
        } catch {
            Logger.network.error("Failed to create SSL handler: \(error, privacy: .public)")
            promise.fail(error)
        }
        
        return promise.futureResult
    }
    
    /// Convenience method to upgrade using the channel reference.
    func upgradeToTLS(role: TLSRole) -> EventLoopFuture<Void>? {
        guard let channel = self.channel else {
            Logger.network.error("Cannot upgrade to TLS: no channel reference")
            return nil
        }
        
        // We need to get our context from the pipeline
        return channel.eventLoop.makeSucceededVoidFuture().flatMap {
            guard let context = try? channel.pipeline.syncOperations.context(handler: self) else {
                return channel.eventLoop.makeFailedFuture(STARTTLSError.handlerNotInPipeline)
            }
            return self.upgradeToTLS(role: role, context: context)
        }
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent {
            switch tlsEvent {
            case .handshakeCompleted:
                self.upgradePromise?.succeed(())
                self.upgradePromise = nil
            case .shutdownCompleted:
                break
            }
        }
        context.fireUserInboundEventTriggered(event)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.network.error("STARTTLS error: \(error, privacy: .public)")
        self.upgradePromise?.fail(error)
        self.upgradePromise = nil
        context.fireErrorCaught(error)
    }
    
    // MARK: - Private
    
    private func createSSLHandler(role: TLSRole) throws -> NIOSSLHandler {
        let tlsConfig = try createTLSConfiguration(role: role)
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        
        switch role {
        case .server:
            return NIOSSLServerHandler(
                context: sslContext,
                customVerificationCallback: trustHandler.verificationCallback
            )
        case .client:
            return try NIOSSLClientHandler(
                context: sslContext,
                serverHostname: nil, // KDE Connect doesn't use SNI
                customVerificationCallback: trustHandler.verificationCallback
            )
        }
    }
    
    private func createTLSConfiguration(role: TLSRole) throws -> TLSConfiguration {
        // Extract certificate and private key from SecIdentity
        var certificate: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certStatus == errSecSuccess, let cert = certificate else {
            throw NIOSSLError.failedToLoadCertificate
        }
        
        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard keyStatus == errSecSuccess, let key = privateKey else {
            throw NIOSSLError.failedToLoadPrivateKey
        }
        
        // Convert to NIOSSLCertificate and NIOSSLPrivateKey
        let certData = SecCertificateCopyData(cert) as Data
        let nioSSLCert = try NIOSSLCertificate(bytes: Array(certData), format: .der)
        
        // For the private key, we need to export it to data
        // This requires the key to be exportable
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
            // Require client certificate (mutual TLS)
            config.certificateVerification = .noHostnameVerification
        case .client:
            config = TLSConfiguration.makeClientConfiguration()
            config.certificateChain = [.certificate(nioSSLCert)]
            config.privateKey = .privateKey(nioSSLKey)
            config.certificateVerification = .noHostnameVerification
        }
        
        // KDE Connect uses TLS 1.2+
        config.minimumTLSVersion = .tlsv12
        
        return config
    }
}
