//
//  MDNSAdvertisementService.swift
//  Soduto
//
//  Created by Sannidhya Roy on 25/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import dnssd

protocol MDNSAdvertisementServiceDelegate: AnyObject {
    func mdnsAdvertisementService(_ service: MDNSAdvertisementService, didRegisterWithName name: String, domain: String)
    func mdnsAdvertisementService(_ service: MDNSAdvertisementService, didFailWithErrorCode errorCode: Int32)
}

final class MDNSAdvertisementService {
    private static let queueSpecificKey = DispatchSpecificKey<UInt8>()
    
    private let queue: DispatchQueue
    private var serviceRef: DNSServiceRef?
    
    weak var delegate: MDNSAdvertisementServiceDelegate?
    
    init(queue: DispatchQueue) {
        self.queue = queue
        self.queue.setSpecific(key: type(of: self).queueSpecificKey, value: 1)
    }
    
    deinit {
        stop()
    }
    
    @discardableResult
    func start(
        deviceId: String,
        deviceName: String,
        deviceType: String,
        protocolVersion: UInt,
        tcpPort: UInt16,
        serviceType: String,
        serviceDomain: String
    ) -> Bool {
        stop()
        
        var txtRecordRef = TXTRecordRef()
        TXTRecordCreate(&txtRecordRef, 0, nil)
        defer { TXTRecordDeallocate(&txtRecordRef) }
        
        let txtValues = [
            ("id", deviceId),
            ("name", deviceName),
            ("type", deviceType),
            ("protocol", String(protocolVersion)),
            ("port", String(tcpPort))
        ]
        
        for (key, value) in txtValues {
            let status = value.withCString { rawValue in
                // DNS-SD TXT record values are limited to 255 bytes
                // Clamp to avoid a fatal UInt8 overflow trap on unexpectedly long values (e.g. device names)
                let len = min(strlen(rawValue), 255)
                return TXTRecordSetValue(&txtRecordRef, key, UInt8(len), rawValue)
            }
            guard status == kDNSServiceErr_NoError else {
                self.delegate?.mdnsAdvertisementService(self, didFailWithErrorCode: status)
                return false
            }
        }
        
        let txtLength = UInt16(TXTRecordGetLength(&txtRecordRef))
        let txtBytes = TXTRecordGetBytesPtr(&txtRecordRef)
        
        var createdServiceRef: DNSServiceRef?
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let registrationError = DNSServiceRegister(
            &createdServiceRef,
            DNSServiceFlags(kDNSServiceFlagsIncludeP2P),
            0,
            deviceId,
            serviceType,
            serviceDomain,
            nil,
            CFSwapInt16HostToBig(tcpPort),
            txtLength,
            txtBytes,
            type(of: self).registrationCallback,
            context
        )
        
        guard registrationError == kDNSServiceErr_NoError, let activeRef = createdServiceRef else {
            self.delegate?.mdnsAdvertisementService(self, didFailWithErrorCode: registrationError)
            return false
        }
        
        let queueError = DNSServiceSetDispatchQueue(activeRef, self.queue)
        guard queueError == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(activeRef)
            self.delegate?.mdnsAdvertisementService(self, didFailWithErrorCode: queueError)
            return false
        }
        
        self.serviceRef = activeRef
        return true
    }
    
    func stop() {
        guard let activeRef = self.serviceRef else { return }
        
        self.serviceRef = nil
        
        if DispatchQueue.getSpecific(key: type(of: self).queueSpecificKey) != nil {
            DNSServiceRefDeallocate(activeRef)
        } else {
            self.queue.sync {
                DNSServiceRefDeallocate(activeRef)
            }
        }
    }
    
    private static let registrationCallback: DNSServiceRegisterReply = {
        _, _, errorCode, name, _, domain, context in
        guard let context = context else { return }
        let service = Unmanaged<MDNSAdvertisementService>.fromOpaque(context).takeUnretainedValue()
        
        if errorCode == kDNSServiceErr_NoError {
            let resolvedName = name.map { String(cString: $0) } ?? ""
            let resolvedDomain = domain.map { String(cString: $0) } ?? ""
            service.delegate?.mdnsAdvertisementService(service, didRegisterWithName: resolvedName, domain: resolvedDomain)
            return
        }
        
        service.delegate?.mdnsAdvertisementService(service, didFailWithErrorCode: errorCode)
    }
}
