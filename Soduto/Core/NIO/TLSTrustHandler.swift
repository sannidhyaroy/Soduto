//
//  TLSTrustHandler.swift
//  Soduto
//
//  Created by Sannidhya Roy on 15/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import NIOCore
import NIOSSL
import os

/// A trust handler that accepts all certificates during TLS handshake.
///
/// KDE Connect's certificate pinning is handled differently with SwiftNIO:
/// 1. During TLS handshake: Accept all certificates (like unpaired mode)
/// 2. After handshake: Extract peer certificate from SSL session
/// 3. Validate against stored certificate using existing `CertificateUtils`
///
/// This approach is necessary because:
/// - NIOSSLCertificate doesn't expose public APIs to extract DER bytes
/// - The internal BoringSSL APIs are version-dependent
/// - Post-handshake validation provides equivalent security
///
/// The security model remains the same:
/// - TLS encryption is established regardless
/// - For paired devices, connection is closed if certificate doesn't match
/// - This happens before any sensitive data is exchanged
final class NIOTrustHandler {
    
    /// The peer certificates received during handshake.
    private(set) var peerCertificates: [NIOSSLCertificate] = []
    
    /// Whether this is for a paired device (affects logging only, validation is post-handshake).
    private let isPaired: Bool
    
    init(isPaired: Bool = false) {
        self.isPaired = isPaired
    }
    
    /// The verification callback that accepts all certificates.
    ///
    /// Certificates are stored for reference but validation is deferred.
    var verificationCallback: NIOSSLCustomVerificationCallback {
        return { [weak self] certificates, promise in
            // Store certificates
            self?.peerCertificates = certificates
            
            // Accept all - validation happens post-handshake
            promise.succeed(.certificateVerified)
        }
    }
}

// MARK: - Certificate Conversion Utilities

/// Utilities for working with NIOSSLCertificate and SecCertificate.
///
/// Note: Direct conversion from NIOSSLCertificate to SecCertificate requires
/// accessing internal BoringSSL APIs. For the migration, we use alternative
/// approaches where possible.
enum NIOCertificateUtils {
    
    /// Creates an NIOSSLCertificate from a SecCertificate.
    ///
    /// This direction (SecCertificate → NIOSSLCertificate) is straightforward
    /// because we can get DER bytes from SecCertificate.
    static func createNIOCertificate(from secCertificate: SecCertificate) throws -> NIOSSLCertificate {
        let derData = SecCertificateCopyData(secCertificate) as Data
        return try NIOSSLCertificate(bytes: Array(derData), format: .der)
    }
    
    /// Compares an NIOSSLCertificate with a SecCertificate.
    ///
    /// Since we can easily convert SecCertificate to NIOSSLCertificate,
    /// we convert the stored certificate and use NIOSSLCertificate's Equatable.
    static func certificatesMatch(_ nioCert: NIOSSLCertificate, _ secCert: SecCertificate) -> Bool {
        do {
            let convertedNioCert = try createNIOCertificate(from: secCert)
            return nioCert == convertedNioCert
        } catch {
            Logger.network.error("Failed to convert SecCertificate for comparison: \(error, privacy: .public)")
            return false
        }
    }
}

// MARK: - Post-Handshake Validator

/// Validates the peer certificate after TLS handshake completes.
///
/// This is used with `NIOTrustHandler` to implement certificate pinning:
/// 1. TLS handshake accepts all certificates
/// 2. After handshake, this validator checks if the peer certificate matches
/// 3. If validation fails, the connection should be closed
struct PostHandshakeValidator {
    
    /// The expected certificate (from device configuration).
    let expectedCertificate: SecCertificate
    
    /// Validates that the peer certificate matches the expected certificate.
    ///
    /// - Parameter peerCertificates: The certificates received during handshake.
    /// - Returns: `true` if the first peer certificate matches the expected certificate.
    func validate(peerCertificates: [NIOSSLCertificate]) -> Bool {
        guard let peerCert = peerCertificates.first else {
            Logger.network.error("No peer certificate to validate")
            return false
        }
        
        let matches = NIOCertificateUtils.certificatesMatch(peerCert, expectedCertificate)
        if !matches {
            Logger.network.error("Post-handshake certificate validation failed")
        }
        return matches
    }
}
