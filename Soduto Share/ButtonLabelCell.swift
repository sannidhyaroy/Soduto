//
//  ButtonCell.swift
//  Soduto Share
//
//  Created by Sannidhya Roy on 03/12/22.
//  Copyright © 2022 Soduto. All rights reserved.
//

import Cocoa

class ButtonLabelCell: NSTableCellView {
    
    @IBOutlet private weak var button: NSButton!
//    @IBOutlet private weak var label: NSTextField!
    
    func configure(_ string: String, tag: Int) {
        button.title = string
        button.tag = tag
    }
}
