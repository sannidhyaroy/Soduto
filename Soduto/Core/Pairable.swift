//
//  Pairable.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-09-05.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation

public enum PairingStatus: Int {
    case Unpaired
    case Requested
    case RequestedByPeer
    case Paired
}

public struct PairingRequest {
    public let connection: Connection
}

/// Delegate protocol for Connection pairing events.
public protocol ConnectionPairingDelegate: AnyObject {
    func connection(_ connection: Connection, receivedPairingRequest request: PairingRequest)
    func connection(_ connection: Connection, pairingFailed error: Error)
    func connection(_ connection: Connection, pairingStatusChanged status: PairingStatus)
}

public protocol Pairable {
    
    var pairingDelegate: ConnectionPairingDelegate? { get set }
    var pairingStatus: PairingStatus { get }
    
    func requestPairing()
    func acceptPairing()
    func declinePairing()
    func unpair()
    func updatePairingStatus(globalStatus: PairingStatus)
}

public protocol PairableClass: AnyObject, Pairable {
}
