//
//  CertificateUtils.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-10-30.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import os
import X509
import Crypto
import _CryptoExtras
import SwiftASN1

public class CertificateUtils {
    
    public enum CertificateError: Error {
        case getOrCreateIdentityFailure(error: NSError?)
        case generateSelfSignedCert // FIXME: provide more information with error
        case generateRSAKeyPairFailure(status: OSStatus)
        case createIdentityFailure(status: OSStatus)
        case deleteIdentityFailure(status: OSStatus)
        case findCertificateFailed(status: OSStatus)
        case createCertificateFailure(error: NSError?)
        case addCertificateFailure(error: NSError?)
        case deleteCertificateFailure(status: OSStatus)
        case addKeyFailure(status: OSStatus)
        case findKeyFailure(status: OSStatus)
        case deleteKeyFailure(status: OSStatus)
        case deleteItemFailure(status: OSStatus)
    }
    
    
    // MARK: Identity functions
    
    public class func findValidIdentity(_ name: String) -> SecIdentity? {
        if let identity = findIdentity(name) {
            var certificate: SecCertificate?
            if SecIdentityCopyCertificate(identity, &certificate) == noErr {
                if validate(certificate: certificate!) {
                    return identity
                }
                else {
                    try? deleteIdentity(name)
                }
            }
        }
        return nil
    }
    
    public class func findIdentity(_ name: String) -> SecIdentity? {
        return SecIdentityCopyPreferred(name as CFString, nil, nil)
    }
    
    public class func getOrCreateIdentity(_ name: String, certCommonName: String, expirationInterval: TimeInterval) throws -> SecIdentity {
        if let identity = findValidIdentity(name) {
            return identity
        }
        else {
            _ = try createIdentity(label: name, certCommonName: certCommonName, expirationInterval: expirationInterval)
            if let identity = findValidIdentity(name) {
                return identity
            }
            else {
                try? deleteIdentity(name)
                throw CertificateError.createIdentityFailure(status: 0)
            }
        }
    }
    
    public class func deleteIdentity(_ name: String) throws {
        let identityOpt = findIdentity(name)
        
        // remove preferences
        SecIdentitySetPreferred(nil, name as CFString, nil)
        SecCertificateSetPreferred(nil, name as CFString, nil)
        
        guard let identity = identityOpt else { return }
        
        // remove identity itself
        try deleteItem(identity, secClass: kSecClassIdentity)
    }
    
    
    // MARK: Certificate functions
    
    public class func addCertificate(_ certificateToAdd: SecCertificate, name: String, dontCopy: Bool = false) throws {
        let certificate: SecCertificate
        if dontCopy {
            certificate = certificateToAdd
        }
        else {
            // Make a deep copy to avoid potential failures while adding (might happen with certificates from SecTrust)
            let data = SecCertificateCopyData(certificateToAdd)
            guard let certificateCopy = SecCertificateCreateWithData(nil, data) else {
                throw CertificateError.addCertificateFailure(error: NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInvalidData), userInfo: nil))
            }
            certificate = certificateCopy
        }
        
        let attrs: [String: AnyObject] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate
        ]
        let addStatus = SecItemAdd(attrs as CFDictionary, nil)
        
        // Determine which certificate reference to use for setting preference
        let keychainCertificate: SecCertificate
        if addStatus == noErr {
            keychainCertificate = certificate
        }
        else if addStatus == errSecDuplicateItem {
            // Certificate already exists in keychain - find it by data and use that reference
            // (This handles orphaned certificates from previous pairings)
            if let existingCert = findCertificateByData(certificate) {
                keychainCertificate = existingCert
            }
            else {
                keychainCertificate = certificate
            }
        }
        else {
            throw CertificateError.addCertificateFailure(error: NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus), userInfo: nil))
        }
        
        let prefStatus = SecCertificateSetPreferred(keychainCertificate, name as CFString, nil)
        if prefStatus != noErr && prefStatus != errSecDuplicateItem {
            try? deleteCertificate(keychainCertificate)
            SecCertificateSetPreferred(nil, name as CFString, nil)
            throw CertificateError.addCertificateFailure(error: NSError(domain: NSOSStatusErrorDomain, code: Int(prefStatus), userInfo: nil))
        }
    }
    
    /// Find an existing certificate in keychain that matches the given certificate's data
    private class func findCertificateByData(_ certificate: SecCertificate) -> SecCertificate? {
        let targetData = SecCertificateCopyData(certificate) as Data
        
        let query: [String: AnyObject] = [
            kSecClass as String: kSecClassCertificate,
            kSecReturnRef as String: kCFBooleanTrue,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == noErr,
              let certs = result as? [SecCertificate] else {
            return nil
        }
        
        for existingCert in certs {
            let existingData = SecCertificateCopyData(existingCert) as Data
            if existingData == targetData {
                return existingCert
            }
        }
        return nil
    }
    
    public class func findCertificate(_ name: String) -> SecCertificate? {
        return SecCertificateCopyPreferred(name as CFString, nil)
    }
    
    public class func updateCertificate(_ certificate: SecCertificate?, name: String) throws {
        try deleteCertificate(name)
        if let cert = certificate {
            try addCertificate(cert, name: name)
        }
    }
    
    private class func deleteCertificate(_ certificate: SecCertificate) throws {
        try deleteItem(certificate, secClass: kSecClassCertificate)
    }
    
    public class func deleteCertificate(_ name: String) throws {
        let certificateOpt = findCertificate(name)
        
        // remove preference
        SecCertificateSetPreferred(nil, name as CFString, nil)
        
        if let certificate = certificateOpt {
            // remove certificate itself
            try? deleteCertificate(certificate)
        }
        
        // Also try to delete certificate by its label attribute directly
        // (certificate might have been added with this name as label, not preference)
        try? deleteItem(name, secClass: kSecClassCertificate)
    }
    
    public class func compareCertificates(_ certificate1: SecCertificate, _ certificate2: SecCertificate) -> Bool {
        let data1 = SecCertificateCopyData(certificate1) as Data
        let data2 = SecCertificateCopyData(certificate2) as Data
        return data1.elementsEqual(data2)
    }
    
    
    // MARK: Protocol v8 SHA256 Functions
    
    /// Returns the SHA256 digest of a certificate as a byte array.
    /// Used for protocol v8 pair verification code generation.
    public class func sha256Digest(for certificate: SecCertificate) -> [UInt8] {
        let data = SecCertificateCopyData(certificate) as Data
        let hash = SHA256.hash(data: data)
        return Array(hash)
    }
    
    /// Returns the SHA256 digest of a certificate as a lowercase hex string.
    /// Used for protocol v8 pair verification code generation.
    public class func sha256DigestString(for certificate: SecCertificate) -> String {
        let digest = sha256Digest(for: certificate)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Returns the SHA256 digest of a certificate formatted for display.
    /// Format: uppercase hex bytes separated by spaces (e.g., "A1 B2 C3...").
    public class func sha256FormattedDigestString(for certificate: SecCertificate) -> String {
        let digest = sha256Digest(for: certificate)
        let hexBytes = digest.map { String(format: "%02hhX", $0) }
        return hexBytes.joined(separator: " ")
    }
    
    /// Generates a pair verification code from two certificate SHA256 hashes.
    ///
    /// The verification code is calculated as:
    /// 1. Sort the two certificate hashes alphabetically
    /// 2. Concatenate them
    /// 3. Take SHA256 of the concatenation
    /// 4. Take the first 8 hex characters, formatted as "XXXX XXXX"
    ///
    /// Both devices will show the same code, allowing users to verify
    /// they are pairing with the correct device (MITM protection).
    ///
    /// - Parameters:
    ///   - localCertHash: SHA256 hex string of the local certificate
    ///   - remoteCertHash: SHA256 hex string of the remote certificate
    /// - Returns: An 8-character verification code formatted as "XXXX XXXX"
    public class func pairVerificationCode(localCertHash: String, remoteCertHash: String, timestamp: Int64? = nil) -> String {
        // Sort and concatenate (ensures both devices get same result)
        var combined = [localCertHash, remoteCertHash].sorted().joined()
        if let timestamp = timestamp {
            combined += String(timestamp)
        }
        
        // SHA256 of combined string
        let hash = SHA256.hash(data: Data(combined.utf8))
        
        // Take first 4 bytes (8 hex chars) and format as "XXXX XXXX"
        let hexChars = Array(hash.prefix(4)).map { String(format: "%02X", $0) }.joined()
        let firstHalf = String(hexChars.prefix(4))
        let secondHalf = String(hexChars.suffix(4))
        
        return "\(firstHalf) \(secondHalf)"
    }
    
    /// Generates a pair verification code from two public keys.
    ///
    /// KDE Connect compares the raw public-key DER byte arrays lexicographically and
    /// concatenates them in descending order before hashing.
    ///
    /// - Parameters:
    ///   - localPublicKey: DER bytes of the local public key.
    ///   - remotePublicKey: DER bytes of the remote public key.
    ///   - timestamp: Optional pairing timestamp (required for protocol v8 requests).
    /// - Returns: An 8-character verification code formatted as "XXXX XXXX"
    public class func pairVerificationCode(localPublicKey: Data, remotePublicKey: Data, timestamp: Int64? = nil) -> String {
        var a = localPublicKey
        var b = remotePublicKey
        if a.lexicographicallyPrecedes(b) {
            swap(&a, &b)
        }
        
        var hash = SHA256()
        hash.update(data: a)
        hash.update(data: b)
        if let timestamp = timestamp {
            hash.update(data: Data(String(timestamp).utf8))
        }
        
        let digest = hash.finalize()
        let hexChars = Array(digest.prefix(4)).map { String(format: "%02X", $0) }.joined()
        let firstHalf = String(hexChars.prefix(4))
        let secondHalf = String(hexChars.suffix(4))
        
        return "\(firstHalf) \(secondHalf)"
    }
    
    /// Generates a pair verification code from two certificates.
    /// Convenience method that handles the SHA256 hashing internally.
    ///
    /// - Parameters:
    ///   - localCert: The local device's certificate
    ///   - remoteCert: The remote device's certificate
    ///   - timestamp: Optional pairing timestamp (required for protocol v8 requests)
    /// - Returns: An 8-character verification code formatted as "XXXX XXXX", or nil if public key extraction fails
    public class func pairVerificationCode(localCert: SecCertificate, remoteCert: SecCertificate, timestamp: Int64? = nil) -> String? {
        guard let localPublicKey = publicKeyDERBytes(for: localCert),
              let remotePublicKey = publicKeyDERBytes(for: remoteCert) else {
            Logger.config.error("Failed to extract public keys for verification code generation")
            return nil
        }
        
        return pairVerificationCode(localPublicKey: localPublicKey, remotePublicKey: remotePublicKey, timestamp: timestamp)
    }
    
    public class func validate(certificate: SecCertificate) -> Bool {
        let oids: [CFString] = [
            kSecOIDX509V1ValidityNotAfter,
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDCommonName
        ]
        let values = SecCertificateCopyValues(certificate, oids as CFArray?, nil) as? [String:[String:AnyObject]]
        return relativeTime(forOID: kSecOIDX509V1ValidityNotAfter, values: values) >= 0.0
        && relativeTime(forOID: kSecOIDX509V1ValidityNotBefore, values: values) <= 0.0
    }
    
    
    // MARK: Key functions
    
    public class func findKey(_ name: String) throws -> SecKey? {
        let query: [String: AnyObject] = [
            kSecClass as String: kSecClassKey,
            kSecReturnRef as String: kCFBooleanTrue,
            kSecAttrLabel as String: name as AnyObject
        ]
        var keyItem: CFTypeRef? = nil
        let status = SecItemCopyMatching(query as CFDictionary, &keyItem)
        if status == errSecSuccess {
            return (keyItem as! SecKey)
        }
        else if status == errSecItemNotFound {
            return nil
        }
        else {
            throw CertificateError.findKeyFailure(status: status)
        }
    }
    
    public class func deleteKey(_ key: SecKey) throws {
        if #available(OSX 10.12, *) {
            if let attrs = SecKeyCopyAttributes(key) as? [String:AnyObject] {
                let appLabel = attrs[kSecAttrApplicationLabel as String] as? Data
                let query: [String: AnyObject] = [
                    kSecClass as String: kSecClassKey,
                    kSecAttrApplicationLabel as String: appLabel as AnyObject
                ]
                let status = SecItemDelete(query as CFDictionary)
                if status != noErr && status != errSecItemNotFound {
                    throw CertificateError.deleteItemFailure(status: status)
                }
            }
        }
        else {
            try deleteItem(key, secClass: kSecClassKey)
        }
    }
    
    public class func deleteKey(_ name: String) throws {
        try deleteItem(name, secClass: kSecClassKey)
    }
    
    
    
    private class func relativeTime(forOID oid: CFString, values: [String:[String:AnyObject]]?) -> Double {
        guard let dateNumber = values?[oid as String]?[kSecPropertyKeyValue as String] as? NSNumber else { return 0.0 }
        return dateNumber.doubleValue - CFAbsoluteTimeGetCurrent();
    }
    
    /// Extracts the public key from a certificate in SubjectPublicKeyInfo (SPKI) DER format.
    ///
    /// This matches Qt's `QSslKey::toDer()` which KDE Connect uses for verification code calculation.
    /// Note: `SecKeyCopyExternalRepresentation` returns raw key data (PKCS#1 for RSA), not SPKI format.
    private class func publicKeyDERBytes(for certificate: SecCertificate) -> Data? {
        // Get certificate DER data
        let certData = SecCertificateCopyData(certificate) as Data
        
        do {
            // Parse certificate using swift-certificates
            let x509Cert = try Certificate(derEncoded: Array(certData))
            
            // Serialize the public key to DER format (SubjectPublicKeyInfo)
            var serializer = DER.Serializer()
            try x509Cert.publicKey.serialize(into: &serializer)
            return Data(serializer.serializedBytes)
        } catch {
            Logger.config.error("Failed to extract public key SPKI DER: \(error, privacy: .public)")
            return nil
        }
    }
    
    private class func deleteItem(_ item: CFTypeRef, secClass: CFString) throws {
        let query: [String: AnyObject] = [
            kSecClass as String: secClass,
            kSecMatchItemList as String: [ item ] as AnyObject
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != noErr && status != errSecItemNotFound {
            throw CertificateError.deleteItemFailure(status: status)
        }
    }
    
    private class func deleteItem(_ name: String, secClass: CFString) throws {
        let query: [String: AnyObject] = [
            kSecClass as String: secClass,
            kSecAttrLabel as String: name as AnyObject
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != noErr && status != errSecItemNotFound {
            throw CertificateError.deleteItemFailure(status: status)
        }
    }
    
    private class func generateRSAKeyPair(sizeInBits: Int, permanent: Bool, label: String) throws -> (SecKey, SecKey) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: sizeInBits,
            kSecAttrLabel as String: label,
            kSecAttrIsPermanent as String: permanent
        ]
        
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let status = error.map { Int32(CFErrorGetCode($0.takeRetainedValue())) } ?? errSecInternalError
            throw CertificateError.generateRSAKeyPairFailure(status: status)
        }
        
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CertificateError.generateRSAKeyPairFailure(status: errSecInternalError)
        }
        
        return (publicKey, privateKey)
    }
    
    public class func createIdentity(label: String, certCommonName: String, expirationInterval: TimeInterval) throws -> SecIdentity? {
        // Clean up any orphaned certificates to avoid conflicts
        // (e.g., user deleted "Soduto Host" preference but not the underlying certificate)
        try? deleteCertificate(label)
        if label != certCommonName {
            try? deleteCertificate(certCommonName)
        }
        
        // Generate RSA keypair (stored permanently in keychain)
        let (publicKey, privateKey) = try generateRSAKeyPair(sizeInBits: 2048, permanent: true, label: label)
        
        try? deleteKey(publicKey) // public key not needed
        
        do {
            // Export private key to PEM format for swift-crypto
            var privateKeyCFData: CFData? = nil
            let exportStatus = SecItemExport(privateKey, .formatOpenSSL, .pemArmour, nil, &privateKeyCFData)
            guard exportStatus == errSecSuccess, let pemData = privateKeyCFData as Data? else {
                throw CertificateError.createIdentityFailure(status: exportStatus)
            }
            
            guard let pemString = String(data: pemData, encoding: .utf8) else {
                throw CertificateError.createIdentityFailure(status: errSecInternalError)
            }
            
            // Parse PEM key with swift-crypto
            let rsaPrivateKey = try _RSA.Signing.PrivateKey(pemRepresentation: pemString)
            
            // Create self-signed certificate using swift-certificates
            let certificate = try createSelfSignedCertificate(
                commonName: certCommonName,
                privateKey: rsaPrivateKey,
                expirationInterval: expirationInterval
            )
            
            // Serialize certificate to DER format
            var serializer = DER.Serializer()
            try certificate.serialize(into: &serializer)
            let derData = Data(serializer.serializedBytes)
            
            // Create SecCertificate from DER data
            guard let secCertificate = SecCertificateCreateWithData(nil, derData as CFData) else {
                throw CertificateError.createCertificateFailure(error: nil)
            }
            
            // Add certificate to keychain
            try addCertificate(secCertificate, name: label)
            guard let savedCertificate = findCertificate(label) else {
                throw CertificateError.addCertificateFailure(error: nil)
            }
            
            // Create identity from certificate and existing private key in keychain
            var identity: SecIdentity? = nil
            let identityStatus = SecIdentityCreateWithCertificate(nil, savedCertificate, &identity)
            if identityStatus == noErr {
                let prefStatus = SecIdentitySetPreferred(identity, label as CFString, nil)
                if prefStatus != noErr {
                    try? deleteCertificate(label)
                    throw CertificateError.createIdentityFailure(status: prefStatus)
                }
                return identity
            }
            else {
                try? deleteCertificate(label)
                throw CertificateError.createIdentityFailure(status: identityStatus)
            }
        }
        catch {
            try? deleteKey(privateKey)
            throw error
        }
    }
    
    /// Creates a self-signed X.509 certificate using swift-certificates
    /// - Parameters:
    ///   - commonName: The CN (Common Name) for the certificate subject/issuer
    ///   - privateKey: The RSA private key to sign the certificate with
    ///   - expirationInterval: How long the certificate should be valid (from now)
    /// - Returns: A signed X.509 certificate
    private class func createSelfSignedCertificate(
        commonName: String,
        privateKey: _RSA.Signing.PrivateKey,
        expirationInterval: TimeInterval
    ) throws -> Certificate {
        // Create distinguished name: CN=commonName, O=Soduto
        // Order matches the original OpenSSL implementation
        let name = try DistinguishedName {
            CommonName(commonName)
            OrganizationName("Soduto")
        }
        
        let now = Date()
        // Valid from 1 year ago (matches original OpenSSL behavior)
        let notValidBefore = now.addingTimeInterval(-365 * 24 * 60 * 60)
        // Valid for the specified expiration interval from now
        let notValidAfter = now.addingTimeInterval(expirationInterval)
        
        // Create self-signed certificate (issuer == subject)
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(1),
            publicKey: .init(privateKey.publicKey),
            notValidBefore: notValidBefore,
            notValidAfter: notValidAfter,
            issuer: name,
            subject: name,
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: .init(privateKey)
        )
        
        return certificate
    }
    
}

extension SecIdentity {
    
    public var certificate: SecCertificate? {
        var certificate: SecCertificate? = nil
        SecIdentityCopyCertificate(self, &certificate)
        return certificate
    }
    
}
