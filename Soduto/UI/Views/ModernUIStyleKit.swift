//
//  ModernUIStyleKit.swift
//  Soduto
//
//  Created on 2025-04-20.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Foundation
import Cocoa

/// A utility class that provides modern styling for UI elements to match modern macOS design
public class ModernUIStyleKit {
    
    // MARK: - Table View Styling
    
    /// Apply modern styling to a table view
    public static func applyModernStyleToTableView(to tableView: NSTableView) {
        if let scrollView = tableView.enclosingScrollView {
            scrollView.wantsLayer = true
            scrollView.layer?.cornerRadius = 8.0
            scrollView.layer?.masksToBounds = true
            
            scrollView.borderType = .lineBorder
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        
        tableView.style = .plain
        // Setting a semi transparent background color to make the table view
        // look slightly darker in light mode and slightly lighter in dark mode
        // this is to match the macOS Sequoia network list
        if #available(macOS 10.14, *) {
            if NSApp.effectiveAppearance.name == .darkAqua {
                tableView.backgroundColor = NSColor.white.withAlphaComponent(0.01)
            } else {
                tableView.backgroundColor = NSColor.black.withAlphaComponent(0.02)
            }
        } else {
            tableView.backgroundColor = NSColor.black.withAlphaComponent(0.02)
        }
        
        tableView.gridColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        
        tableView.selectionHighlightStyle = .none
    }
}

/// A custom NSTableRowView class that provides styling to match modern macOS design
public class ModernTableRowView: NSTableRowView {
    override public var isEmphasized: Bool {
        get { return false }
        set { }
    }
    
    override public var isSelected: Bool {
        didSet {
            // Force redraw when selection changes
            self.needsDisplay = true
        }
    }
    
    override public func drawSelection(in dirtyRect: NSRect) {
        // Don't draw the default selection background
    }
    
    override public func drawBackground(in dirtyRect: NSRect) {
        // Keep background fully transparent
        NSColor.clear.set()
        dirtyRect.fill()
    }
}
