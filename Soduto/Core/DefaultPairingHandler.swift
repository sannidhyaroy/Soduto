//
//  DefaultPairingHandler.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-09-05.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation

public protocol PairingHandlerDelegate: AnyObject {
    
    func send(_ packet: DataPacket) -> Bool
    
    var peerCertificate: SecCertificate? { get }
    
}


/// Pairing state machine for tracking and managing connection pairing status.
///
/// This class handles the pairing state transitions and certificate management.
/// Connection uses this internally to track pairing state; all delegate callbacks
/// are handled directly by Connection via ConnectionPairingDelegate.
public class DefaultPairingHandler: Pairable {
    
    // MARK: Types
    
    public enum Error: Swift.Error {
        case alreadyPaired
        case pairingAlreadyRequested
        case declinedByPeer
    }
    
    
    // MARK: Properties
    
    static let pairingTimoutInterval: TimeInterval = 30.0
    
    /// A delegate object providing needed services for this handler (like packet sending)
    public weak var delegate: PairingHandlerDelegate? = nil
    
    private let config: DeviceConfiguration
    private var pairingTimeout: Timer? = nil
    private var pairingTimestamp: Int64? = nil
    
    /// The pair verification code for protocol v8+.
    /// This 8-character code (formatted as "XXXX XXXX") should be displayed to users
    /// during pairing so they can verify both devices show the same code.
    /// Only available when both local and peer certificates are present.
    public private(set) var verificationCode: String?
    
    
    // MARK: Init / Deinit
    
    public init(config: DeviceConfiguration) {
        self.config = config
        self.pairingStatus = .Unpaired
        if self.config.isPaired {
            self.trySetPaired()
        }
    }
    
    
    // MARK: Pairable
    
    public var pairingDelegate: ConnectionPairingDelegate? {
        get { return nil }
        set { /* Connection handles delegate callbacks directly */ }
    }
    
    public private(set) var pairingStatus: PairingStatus {
        willSet {
            assert(newValue != .Paired || self.canSetPaired(), "Can't set pairingStatus to .Paired. Should always use trySetPaired method to safely set paierd status")
        }
        didSet {
            guard self.pairingStatus != oldValue else { return }
            
            if self.pairingStatus == .Unpaired {
                self.config.certificate = nil
                self.pairingTimestamp = nil
                self.verificationCode = nil
            }
            
            self.pairingTimeout?.invalidate()
            self.pairingTimeout = nil
            
            if self.pairingStatus == .Requested || self.pairingStatus == .RequestedByPeer {
                let status = self.pairingStatus
                let timeoutInterval = DefaultPairingHandler.pairingTimoutInterval
                self.pairingTimeout = Timer.compatScheduledTimer(withTimeInterval: timeoutInterval, repeats: false) { [weak self] (timer) in
                    guard let strongSelf = self else { return }
                    // Every change to pairingStatus should invalidate previous timeout,
                    // so if we are here, pairingStatus should still be the same
                    assert(strongSelf.pairingStatus == status, "pairingStatus expected to not be changed")
                    strongSelf.declinePairing()
                }
            }
            // Note: Connection handles pairingDelegate callbacks directly via ConnectionPairingDelegate
        }
    }
    
    public func requestPairing() {
        assert(self.delegate != nil, "Delegate required for \(type(of: self))")
        
        switch self.pairingStatus {
        case .Unpaired:
            self.pairingTimestamp = Int64(Date().timeIntervalSince1970)
            self.pairingStatus = .Requested
            _ = self.delegate!.send(DataPacket.pairPacket(timestamp: self.pairingTimestamp))
            self.generateVerificationCode()
        case .RequestedByPeer:
            self.acceptPairing()
        case .Requested, .Paired:
            // Already requesting or paired - no action needed
            // Connection handles error callbacks directly
            break
        }
    }
    
    public func acceptPairing() {
        assert(self.delegate != nil, "Delegate required for \(type(of: self))")
        
        if self.config.certificate == nil {
            self.config.certificate = self.delegate!.peerCertificate
        }
        
        // We need to send pair packet before setting pairedStatus.
        // Otherwise pairing status notifications might trigger other data packets to be sent and if
        // such packets are sent befor pairing, they might be discarded or even cause other device to cancel pairing
        if self.canSetPaired() {
            _ = self.delegate?.send(DataPacket.pairPacket())
            self.trySetPaired()
        }
        
        if self.pairingStatus != .Paired {
            _  = self.delegate?.send(DataPacket.unpairPacket())
        }
    }
    
    public func declinePairing() {
        assert(self.delegate != nil, "Delegate required for \(type(of: self))")
        
        self.pairingStatus = .Unpaired
        _ = self.delegate!.send(DataPacket.unpairPacket())
    }
    
    public func unpair() {
        assert(self.delegate != nil, "Delegate required for \(type(of: self))")
        
        self.pairingStatus = .Unpaired
        _ = self.delegate!.send(DataPacket.unpairPacket())
    }
    
    public func updatePairingStatus(globalStatus: PairingStatus) {
        switch globalStatus {
        case .Paired:
            self.trySetPaired()
        case .Unpaired:
            self.pairingStatus = .Unpaired
        case .Requested:
            self.pairingStatus = .Requested
        case .RequestedByPeer:
            self.pairingStatus = .RequestedByPeer
        }
    }
    
    /// Direct status setter for Connection to use during pairing transitions.
    /// This triggers didSet observers like direct assignment would.
    internal func setStatus(_ status: PairingStatus) {
        self.pairingStatus = status
    }
    
    
    // MARK: Public Methods
    
    /// Updates the verification code based on current certificates.
    /// Call this when the peer certificate becomes available during TLS handshake.
    public func updateVerificationCode() {
        generateVerificationCode()
    }
    
    /// Sets the pairing timestamp used for verification code generation.
    /// For protocol v8 this should be the timestamp from the original pair request.
    internal func setPairingTimestamp(_ timestamp: Int64?) {
        self.pairingTimestamp = timestamp
        generateVerificationCode()
    }
    
    // MARK: Private methods
    
    private func canSetPaired() -> Bool {
        return self.config.certificate != nil
    }
    
    private func trySetPaired() {
        if self.canSetPaired() {
            self.pairingStatus = .Paired
        }
        else {
            self.pairingStatus = .Unpaired
        }
    }
    
    /// Generates the pair verification code from both certificates.
    /// The code is only generated when both local and peer certificates are available.
    private func generateVerificationCode() {
        guard let hostIdentity = config.hostCertificate,
              let hostCert = hostIdentity.certificate,
              let peerCert = delegate?.peerCertificate else {
            verificationCode = nil
            return
        }
        
        verificationCode = CertificateUtils.pairVerificationCode(
            localCert: hostCert,
            remoteCert: peerCert,
            timestamp: pairingTimestamp
        )
    }
}


// MARK: - DataPacket (Pairing)

/// Pairing data packet utilities
public extension DataPacket {
    
    // MARK: Types
    
    enum PairingProperty: String {
        case pairFlag = "pair"
        case timestamp = "timestamp"
    }
    
    enum PairingError: Error {
        case wrongType
        case invalidPairFlag
        case invalidTimestamp
    }
    
    
    // MARK: Properties
    
    static let pairingPacketType = "kdeconnect.pair"
    
    var isPairingPacket: Bool { return self.type == DataPacket.pairingPacketType }
    
    
    // MARK: Public static methods
    
    static func pairPacket(timestamp: Int64? = nil) -> DataPacket {
        var body: DataPacket.Body = [
            PairingProperty.pairFlag.rawValue: NSNumber(value: true)
        ]
        if let timestamp = timestamp {
            body[PairingProperty.timestamp.rawValue] = NSNumber(value: timestamp)
        }
        return DataPacket(type: pairingPacketType, body: body)
    }
    
    static func unpairPacket() -> DataPacket {
        return DataPacket(type: pairingPacketType, body: [
            PairingProperty.pairFlag.rawValue: NSNumber(value: false)
        ])
    }
    
    
    // MARK: Public methods
    
    func getPairFlag() throws -> Bool {
        try self.validatePairingType()
        guard let value = body[PairingProperty.pairFlag.rawValue] as? NSNumber else { throw PairingError.invalidPairFlag }
        return value.boolValue
    }
    
    func getPairingTimestamp() throws -> Int64 {
        try self.validatePairingType()
        guard let value = body[PairingProperty.timestamp.rawValue] as? NSNumber else { throw PairingError.invalidTimestamp }
        return value.int64Value
    }
    
    func validatePairingType() throws {
        guard isPairingPacket else { throw PairingError.wrongType }
    }
}
