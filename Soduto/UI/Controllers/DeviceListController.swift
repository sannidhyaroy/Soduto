//
//  DeviceListController.swift
//  Soduto
//
//  Created by Giedrius on 2017-05-23.
//  Copyright © 2017 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import SwiftUI
import os

/// Modern SwiftUI-based device list controller
/// Maintains backward compatibility with storyboard-based preferences
class DeviceListController: NSViewController {
    
    var deviceDataSource: DeviceDataSource? {
        didSet {
            viewModel?.deviceDataSource = deviceDataSource
            viewModel?.refreshDevices()
        }
    }
    
    @IBOutlet weak var deviceList: NSTableView? // Kept for storyboard compatibility, not used
    
    private var viewModel: DevicesListViewModel?
    private var hostingView: NSHostingView<DevicesListView>?
    
    func refreshDeviceList() {
        viewModel?.refreshDevices()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupSwiftUIView()
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        // Removed automatic broadcast - not part of official KDE Connect protocol
        // Only broadcast on: app start, network change, manual Cmd+R
        
        // Setup SwiftUI view if not already done (in case viewDidLoad was too early)
        if viewModel == nil {
            setupSwiftUIView()
        }
        
        viewModel?.refreshDevices()
    }
    
    private func setupSwiftUIView() {
        // Get deviceManager safely
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            Logger.ui.notice("AppDelegate not available yet, will setup later")
            return
        }
        
        let deviceManager = appDelegate.deviceManager
        
        // Create view model
        let viewModel = DevicesListViewModel(
            deviceDataSource: deviceDataSource,
            deviceManager: deviceManager
        )
        self.viewModel = viewModel
        
        // Create SwiftUI view
        let swiftUIView = DevicesListView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: swiftUIView)
        self.hostingView = hostingView
        
        // Remove existing subviews and add hosting view
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(hostingView)
        
        // Setup constraints
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    @IBAction func showDeviceInfo(_ sender: Any?) {
        // This action is now handled internally by SwiftUI view
        // Kept for storyboard compatibility
    }
    
}

