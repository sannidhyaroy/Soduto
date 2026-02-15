//
//  BaseConnection.swift
//  Soduto
//
//  Created by Sannidhya Roy on 15/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import CocoaAsyncSocket

// MARK: - BaseConnection Protocol

/// Protocol that captures the common API between Connection and NIOConnection.
///
/// This protocol enables Device and other components to work with either
/// connection implementation during the migration from CocoaAsyncSocket to SwiftNIO.
public protocol BaseConnection: AnyObject, Pairable {
    
    // MARK: - Types
    
    /// Connection state enumeration.
    associatedtype ConnectionState
    
    /// Completion handler for packet sending operations.
    typealias SendingCompletionHandler = ((_ packetSent: Bool, _ payloadSent: Bool) -> Void)
    
    // MARK: - Properties
    
    /// The current state of the connection.
    var state: ConnectionState { get }
    
    /// The identity packet received from the peer.
    var identity: DataPacket? { get }
    
    /// The peer's TLS certificate.
    var peerCertificate: SecCertificate? { get }
    
    /// The peer's socket address.
    var peerAddress: SocketAddress { get }
    
    /// The host's TLS certificate.
    var hostCertificate: SecCertificate? { get }
    
    // MARK: - Sending
    
    /// Sends a data packet with optional completion handler.
    ///
    /// - Parameters:
    ///   - dataPacket: The packet to send.
    ///   - whenCompleted: Optional completion handler called when sending finishes.
    /// - Returns: `true` if the send was accepted, `false` if capacity exceeded.
    @discardableResult
    func send(_ dataPacket: DataPacket, whenCompleted: SendingCompletionHandler?) -> Bool
    
    /// Sends a data packet without completion handler.
    @discardableResult
    func send(_ dataPacket: DataPacket) -> Bool
    
    // MARK: - Reading
    
    /// Reads a single packet then stops.
    func readOnePacket()
    
    /// Reads packets continuously.
    func readPackets()
    
    // MARK: - Lifecycle
    
    /// Reclaims unsent packets from a closed connection.
    func reclaimUnsentPackets() -> [(dataPacket: DataPacket, completionHandler: SendingCompletionHandler?)]
    
    /// Closes the connection immediately.
    func close()
    
    /// Closes the connection after all pending writes complete.
    func closeAfterWriting()
    
    // MARK: - TLS Support
    
    /// Secures a server socket for payload transfer.
    func secureServerSocket(_ socket: GCDAsyncSocket)
    
    /// Validates whether the peer certificate should be trusted.
    func shouldTrustPeerCertificate(_ peerCertificate: SecCertificate) -> Bool
}

// MARK: - BaseConnectionDelegate Protocol

/// Delegate protocol for connection events that works with any BaseConnection.
public protocol BaseConnectionDelegate: AnyObject {
    associatedtype ConnectionType: BaseConnection
    
    func connection(_ connection: ConnectionType, didSwitchToState state: ConnectionType.ConnectionState)
    func connection(_ connection: ConnectionType, didSendPacket packet: DataPacket, uploadedPayload: Bool)
    func connection(_ connection: ConnectionType, didReadPacket packet: DataPacket)
    func connectionCapacityChanged(_ connection: ConnectionType)
}

// MARK: - Type-Erased Wrapper

/// Type-erased wrapper for BaseConnection that allows storing heterogeneous connections.
///
/// This wrapper enables collections like `[AnyBaseConnection]` to hold both
/// Connection and NIOConnection instances.
public final class AnyBaseConnection: Pairable, Hashable {
    
    // MARK: - Properties
    
    private let _identity: () -> DataPacket?
    private let _peerCertificate: () -> SecCertificate?
    private let _peerAddress: () -> SocketAddress
    private let _hostCertificate: () -> SecCertificate?
    private let _pairingStatus: () -> PairingStatus
    private let _send: (DataPacket, BaseConnection.SendingCompletionHandler?) -> Bool
    private let _sendSimple: (DataPacket) -> Bool
    private let _readOnePacket: () -> Void
    private let _readPackets: () -> Void
    private let _reclaimUnsentPackets: () -> [(dataPacket: DataPacket, completionHandler: BaseConnection.SendingCompletionHandler?)]
    private let _close: () -> Void
    private let _closeAfterWriting: () -> Void
    private let _secureServerSocket: (GCDAsyncSocket) -> Void
    private let _shouldTrustPeerCertificate: (SecCertificate) -> Bool
    private let _requestPairing: () -> Void
    private let _acceptPairing: () -> Void
    private let _declinePairing: () -> Void
    private let _unpair: () -> Void
    private let _updatePairingStatus: (PairingStatus) -> Void
    private let _isStateOpen: () -> Bool
    private let _isStateClosed: () -> Bool
    private let _objectIdentifier: ObjectIdentifier
    
    /// The underlying connection object.
    public let wrapped: AnyObject
    
    // MARK: - Initialization
    
    /// Creates a type-erased wrapper for a Connection.
    public init(_ connection: Connection) {
        self.wrapped = connection
        self._objectIdentifier = ObjectIdentifier(connection)
        self._identity = { connection.identity }
        self._peerCertificate = { connection.peerCertificate }
        self._peerAddress = { connection.peerAddress }
        self._hostCertificate = { connection.hostCertificate }
        self._pairingStatus = { connection.pairingStatus }
        self._send = { connection.send($0, whenCompleted: $1) }
        self._sendSimple = { connection.send($0) }
        self._readOnePacket = { connection.readOnePacket() }
        self._readPackets = { connection.readPackets() }
        self._reclaimUnsentPackets = { connection.reclaimUnsentPackets() }
        self._close = { connection.close() }
        self._closeAfterWriting = { connection.closeAfterWriting() }
        self._secureServerSocket = { connection.secureServerSocket($0) }
        self._shouldTrustPeerCertificate = { connection.shouldTrustPeerCertificate($0) }
        self._requestPairing = { connection.requestPairing() }
        self._acceptPairing = { connection.acceptPairing() }
        self._declinePairing = { connection.declinePairing() }
        self._unpair = { connection.unpair() }
        self._updatePairingStatus = { connection.updatePairingStatus(globalStatus: $0) }
        self._isStateOpen = { connection.state == .Open }
        self._isStateClosed = { connection.state == .Closed }
    }
    
    /// Creates a type-erased wrapper for an NIOConnection.
    public init(_ connection: NIOConnection) {
        self.wrapped = connection
        self._objectIdentifier = ObjectIdentifier(connection)
        self._identity = { connection.identity }
        self._peerCertificate = { connection.peerCertificate }
        self._peerAddress = { connection.peerAddress }
        self._hostCertificate = { connection.hostCertificate }
        self._pairingStatus = { connection.pairingStatus }
        self._send = { connection.send($0, whenCompleted: $1) }
        self._sendSimple = { connection.send($0) }
        self._readOnePacket = { connection.readOnePacket() }
        self._readPackets = { connection.readPackets() }
        self._reclaimUnsentPackets = { connection.reclaimUnsentPackets() }
        self._close = { connection.close() }
        self._closeAfterWriting = { connection.closeAfterWriting() }
        self._secureServerSocket = { connection.secureServerSocket($0) }
        self._shouldTrustPeerCertificate = { connection.shouldTrustPeerCertificate($0) }
        self._requestPairing = { connection.requestPairing() }
        self._acceptPairing = { connection.acceptPairing() }
        self._declinePairing = { connection.declinePairing() }
        self._unpair = { connection.unpair() }
        self._updatePairingStatus = { connection.updatePairingStatus(globalStatus: $0) }
        self._isStateOpen = { connection.state == .Open }
        self._isStateClosed = { connection.state == .Closed }
    }
    
    // MARK: - BaseConnection Properties
    
    public var identity: DataPacket? { _identity() }
    public var peerCertificate: SecCertificate? { _peerCertificate() }
    public var peerAddress: SocketAddress { _peerAddress() }
    public var hostCertificate: SecCertificate? { _hostCertificate() }
    public var isOpen: Bool { _isStateOpen() }
    public var isClosed: Bool { _isStateClosed() }
    
    // MARK: - BaseConnection Methods
    
    @discardableResult
    public func send(_ dataPacket: DataPacket, whenCompleted: BaseConnection.SendingCompletionHandler?) -> Bool {
        _send(dataPacket, whenCompleted)
    }
    
    @discardableResult
    public func send(_ dataPacket: DataPacket) -> Bool {
        _sendSimple(dataPacket)
    }
    
    public func readOnePacket() { _readOnePacket() }
    public func readPackets() { _readPackets() }
    
    public func reclaimUnsentPackets() -> [(dataPacket: DataPacket, completionHandler: BaseConnection.SendingCompletionHandler?)] {
        _reclaimUnsentPackets()
    }
    
    public func close() { _close() }
    public func closeAfterWriting() { _closeAfterWriting() }
    public func secureServerSocket(_ socket: GCDAsyncSocket) { _secureServerSocket(socket) }
    public func shouldTrustPeerCertificate(_ peerCertificate: SecCertificate) -> Bool { _shouldTrustPeerCertificate(peerCertificate) }
    
    // MARK: - Pairable
    
    public var pairingDelegate: PairableDelegate?
    
    public var pairingStatus: PairingStatus { _pairingStatus() }
    
    public func requestPairing() { _requestPairing() }
    public func acceptPairing() { _acceptPairing() }
    public func declinePairing() { _declinePairing() }
    public func unpair() { _unpair() }
    public func updatePairingStatus(globalStatus: PairingStatus) { _updatePairingStatus(globalStatus) }
    
    // MARK: - Hashable
    
    public static func == (lhs: AnyBaseConnection, rhs: AnyBaseConnection) -> Bool {
        lhs._objectIdentifier == rhs._objectIdentifier
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(_objectIdentifier)
    }
    
    // MARK: - Type Checking
    
    /// Returns the underlying Connection if this wrapper contains one.
    public var asConnection: Connection? {
        wrapped as? Connection
    }
    
    /// Returns the underlying NIOConnection if this wrapper contains one.
    public var asNIOConnection: NIOConnection? {
        wrapped as? NIOConnection
    }
}
