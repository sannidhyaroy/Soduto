//
//  MDNSBrowseService.swift
//  Soduto
//
//  Created by Sannidhya Roy on 25/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import Network

protocol MDNSBrowseServiceDelegate: AnyObject {
    func mdnsBrowseService(_ service: MDNSBrowseService, didUpdateState state: NWBrowser.State)
    func mdnsBrowseService(_ service: MDNSBrowseService, didReceiveChanges changes: Set<NWBrowser.Result.Change>)
}

final class MDNSBrowseService {
    private let queue: DispatchQueue
    private var browser: NWBrowser?
    
    weak var delegate: MDNSBrowseServiceDelegate?
    
    /// The browser's current result set. Read from the browse queue.
    var currentResults: Set<NWBrowser.Result> {
        return browser?.browseResults ?? []
    }
    
    init(queue: DispatchQueue) {
        self.queue = queue
    }
    
    deinit {
        stop()
    }
    
    func start(serviceType: String, serviceDomain: String) {
        stop()
        
        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: serviceDomain)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.delegate?.mdnsBrowseService(self, didUpdateState: state)
        }
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self = self else { return }
            self.delegate?.mdnsBrowseService(self, didReceiveChanges: changes)
        }
        
        self.browser = browser
        browser.start(queue: queue)
    }
    
    func stop() {
        browser?.cancel()
        browser = nil
    }
}
