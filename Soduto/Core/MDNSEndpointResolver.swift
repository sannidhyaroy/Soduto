//
//  MDNSEndpointResolver.swift
//  Soduto
//
//  Created by Sannidhya Roy on 25/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import Network
import os

protocol MDNSEndpointResolverDelegate: AnyObject {
    func mdnsEndpointResolver(_ resolver: MDNSEndpointResolver, didResolveAddress address: String, forDeviceId deviceId: String, tcpPort: UInt16)
}

final class MDNSEndpointResolver {
    private static let resolutionTimeout: TimeInterval = 5.0
    
    private let queue: DispatchQueue
    
    weak var delegate: MDNSEndpointResolverDelegate?
    
    init(queue: DispatchQueue) {
        self.queue = queue
    }
    
    func resolve(endpoint: NWEndpoint, deviceId: String, tcpPort: UInt16) {
        let parameters = NWParameters.udp
        let connection = NWConnection(to: endpoint, using: parameters)
        var resolutionFinished = false
        
        connection.stateUpdateHandler = { [weak self] state in
            guard !resolutionFinished else { return }
            
            switch state {
            case .ready:
                resolutionFinished = true
                guard let self = self else {
                    connection.cancel()
                    return
                }
                
                if let path = connection.currentPath,
                   let remoteEndpoint = path.remoteEndpoint,
                   let ipAddress = self.extractIPAddress(from: remoteEndpoint) {
                    Logger.network.debug("mDNS resolved \(deviceId, privacy: .public) to \(ipAddress, privacy: .public):\(tcpPort, privacy: .public)")
                    self.delegate?.mdnsEndpointResolver(self, didResolveAddress: ipAddress, forDeviceId: deviceId, tcpPort: tcpPort)
                } else {
                    Logger.network.debug("mDNS: could not extract address for \(deviceId, privacy: .public)")
                }
                
                connection.cancel()
                
            case .failed(let error):
                resolutionFinished = true
                Logger.network.debug("mDNS endpoint resolution failed for \(deviceId, privacy: .public): \(error, privacy: .public)")
                connection.cancel()
                
            case .cancelled:
                resolutionFinished = true
                break
                
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        
        queue.asyncAfter(deadline: .now() + type(of: self).resolutionTimeout) {
            guard !resolutionFinished else { return }
            
            resolutionFinished = true
            Logger.network.debug("mDNS endpoint resolution timeout for \(deviceId, privacy: .public)")
            connection.cancel()
        }
    }
    
    private func extractIPAddress(from endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                return "\(addr)"
            case .ipv6(let addr):
                return "\(addr)"
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
