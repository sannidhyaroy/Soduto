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
/// are handled directly by Connection via PairableDelegate.
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
    
    
    // MARK: Init / Deinit
    
    public init(config: DeviceConfiguration) {
        self.config = config
        self.pairingStatus = .Unpaired
        if self.config.isPaired {
            self.trySetPaired()
        }
    }
    
    
    // MARK: Pairable
    
    public var pairingDelegate: PairableDelegate? {
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
            // Note: Connection handles pairingDelegate callbacks directly via PairableDelegate
        }
    }
    
    public func requestPairing() {
        assert(self.delegate != nil, "Delegate required for \(type(of: self))")
        
        switch self.pairingStatus {
        case .Unpaired:
            self.pairingStatus = .Requested
            _ = self.delegate!.send(DataPacket.pairPacket())
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
}


// MARK: - DataPacket (Pairing)

/// Pairing data packet utilities
public extension DataPacket {
    
    // MARK: Types
    
    enum PairingProperty: String {
        case pairFlag = "pair"
    }
    
    enum PairingError: Error {
        case wrongType
        case invalidPairFlag
    }
    
    
    // MARK: Properties
    
    static let pairingPacketType = "kdeconnect.pair"
    
    var isPairingPacket: Bool { return self.type == DataPacket.pairingPacketType }
    
    
    // MARK: Public static methods
    
    static func pairPacket() -> DataPacket {
        return DataPacket(type: pairingPacketType, body: [
            PairingProperty.pairFlag.rawValue: NSNumber(value: true)
        ])
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
    
    func validatePairingType() throws {
        guard isPairingPacket else { throw PairingError.wrongType }
    }
}
