//
//  StableHashing.swift
//  Soduto
//
//  Created by Sannidhya Roy on 27/01/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import CryptoKit

/// Deterministic, stable hashing utilities.
/// Safe across app launches, OS versions, and Swift versions.
enum StableHashing {
    
    // MARK: - Core Hashing
    
    /// Returns a deterministic SHA-256 hex digest for the given string
    /// - Parameter string: Input string to hash
    /// - Returns: 64-character lowercase hexadecimal SHA-256 digest
    static func sha256(_ string: String) -> String {
        sha256(data: Data(string.utf8))
    }
    
    /// Returns a full, deterministic SHA-256 hex digest for raw data
    /// - Parameter data: Input data to hash
    /// - Returns: 64-character lowercase hexadecimal SHA-256 digest
    static func sha256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    
    // MARK: - Short Hashing
    
    /// Returns a truncated SHA-256 hash
    /// - Parameters:
    ///   - string: Input string to hash
    ///   - length: Number of hex characters to keep (default: 16)
    /// - Returns: Truncated SHA-256 hex string
    static func shortSha256(_ string: String, length: Int = 16) -> String {
        let full = sha256(string)
        return String(full.prefix(max(0, length)))
    }
    
    /// Returns a truncated SHA-256 hash for raw data
    /// - Parameters:
    ///   - data: Input data to hash
    ///   - length: Number of hex characters to keep (default: 16)
    /// - Returns: Truncated SHA-256 hex string
    static func shortSha256(data: Data, length: Int = 16) -> String {
        let full = sha256(data: data)
        return String(full.prefix(max(0, length)))
    }
    
    
    // MARK: - Composite Hashing
    
    /// Hashes multiple string components in a deterministic order.
    /// Useful when building stable identifiers from multiple fields without manual concatenation bugs.
    /// - Parameter components: Ordered components to hash
    /// - Returns: Stable SHA-256 digest
    static func sha256(components: [String]) -> String {
        let joined = components.joined(separator: "\u{1F}")
        return sha256(joined)
    }
}
