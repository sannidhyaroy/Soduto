//
//  FindMyWindowController.swift
//  Soduto
//
//  Created by Sannidhya Roy on 08/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import AppKit
import SwiftUI

// Borderless NSWindow that can become key, required for keyboard shortcuts (Return to stop ringing)
// and to suppress the "-[NSWindow makeKeyWindow] called on … canBecomeKeyWindow returned NO" warning
// that borderless windows produce when NSApp.activate is called.
private final class FindMyAlertWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FindMyWindowController: NSWindowController, NSWindowDelegate {

    var onStop: (() -> Void)?

    static func make(initiatorName: String, onStop: @escaping () -> Void) -> FindMyWindowController {
        let view = FindMyAlertView(initiatorName: initiatorName, onStop: onStop)
        let hosting = NSHostingController(rootView: view)

        // Clip the hosting view to rounded corners at the NSView layer so that:
        // (a) the NSVisualEffectView blur doesn't bleed past the rounded rect, and
        // (b) the window's non-opaque shadow follows the visible rounded shape.
        hosting.view.wantsLayer = true
        hosting.view.layer?.cornerRadius = 20
        hosting.view.layer?.masksToBounds = true

        let window = FindMyAlertWindow(contentViewController: hosting)
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 340, height: 450))
        window.center()

        let controller = FindMyWindowController(window: window)
        controller.onStop = onStop
        window.delegate = controller
        return controller
    }

    public func windowWillClose(_ notification: Notification) {
        let handler = onStop
        onStop = nil
        handler?()
    }
}
