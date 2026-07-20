//
//  RunCommandsWindowController.swift
//  Soduto
//
//  Created on 2025-04-19.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Cocoa
import SwiftUI

// MARK: - RunCommandsWindowControllerDelegate

protocol RunCommandsWindowControllerDelegate: AnyObject {
    func getLocalCommands() -> [RunCommandService.Command]?
    func saveLocalCommands(_ commands: [RunCommandService.Command])
}

// MARK: - RunCommandsWindowController

class RunCommandsWindowController: NSWindowController {
    
    private let viewModel = RunCommandsViewModel()
    
    weak var delegate: RunCommandsWindowControllerDelegate? {
        didSet { viewModel.delegate = delegate }
    }
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Run Commands"
        window.minSize = NSSize(width: 400, height: 300)
        window.center()
        self.init(window: window)
        window.contentViewController = NSHostingController(rootView: RunCommandsView(viewModel: self.viewModel))
    }
    
    /// Presents the window as a sheet attached to `parentWindow`, with a Done button to dismiss it.
    func presentAsSheet(in parentWindow: NSWindow) {
        viewModel.reload()
        viewModel.isSheet = true
        viewModel.dismissSheet = { [weak self, weak parentWindow] in
            guard let self, let window = self.window, let parentWindow else { return }
            parentWindow.endSheet(window)
        }
        parentWindow.beginSheet(window!) { [weak self] _ in
            self?.viewModel.isSheet = false
            self?.viewModel.dismissSheet = nil
        }
    }
    
    override func showWindow(_ sender: Any?) {
        viewModel.reload()
        viewModel.isSheet = false
        viewModel.dismissSheet = nil
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
    }
}
