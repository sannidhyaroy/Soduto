//
//  DeviceScrubberItemView.swift
//  Soduto Share
//
//  Created by Sannidhya Roy on 30/01/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa

class DeviceScrubberItemView: NSScrubberItemView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    
    var isDisabledVisually: Bool = false {
        didSet { updateAppearance() }
    }
    
    override var isSelected: Bool {
        didSet { updateAppearance() }
    }
    
    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }
    
    private func updateAppearance() {
        if isDisabledVisually {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            alphaValue = 0.4
        } else if isHighlighted {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
            alphaValue = 1.0
        } else if isSelected {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
            alphaValue = 1.0
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
            alphaValue = 1.0
        }
    }
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .labelColor
        nameLabel.backgroundColor = .clear
        nameLabel.isBordered = false
        nameLabel.isEditable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(iconView)
        addSubview(nameLabel)
        
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    func configure(name: String, symbolName: String) {
        nameLabel.stringValue = name
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = .labelColor
    }
}
