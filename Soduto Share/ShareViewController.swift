//
//  ShareViewController.swift
//  Soduto Share
//
//  Created by Sannidhya Roy on 03/12/22.
//  Copyright © 2022 Soduto. All rights reserved.
//

import Cocoa

class ShareViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    
    //MARK: Service Properties
    
//    private var devices: [Device.Id:Device] = [:]
//    private var validDevices: [Device] { return self.devices.values.filter { $0.isReachable && $0.pairingStatus == .Paired } }
    
    var nameArray = ["Pixel 6 Pro", "Asus Vivobook", "Sannidhya's iPad", "Satyajit's iPhone"]
    
    //MARK: - NSTableViewDataSource
    
    func numberOfRows(in tableView: NSTableView) -> Int {
//        self.validDevices.count
        nameArray.count
    }
    
    //MARK: -NSTableViewDelegate
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn = tableColumn else {
            return nil
        }
        
//        let rowString = "\(row)"
        
        if tableColumn.identifier == .labelColumn,
                  let cell = tableView.makeView(withIdentifier: .labelIdentifier, owner: self) as? ButtonLabelCell
        {
            // Insert code for button column
            cell.configure(nameArray[row])
            return cell
        }
        else {
            return nil
        }
    }
    
    //MARK: -NSViewController

    override var nibName: NSNib.Name? {
        return NSNib.Name("ShareViewController")
    }

    override func loadView() {
        super.loadView()
    
        // Insert code here to customize the view
        let item = self.extensionContext!.inputItems[0] as! NSExtensionItem
        if let attachments = item.attachments {
            NSLog("Attachments = %@", attachments as NSArray)
        } else {
            NSLog("No Attachments")
        }
//        guard self.validDevices.count > 0 else { self.extensionContext!.cancelRequest(withError: NSError()) }
    }

    @IBAction func send(_ sender: AnyObject?) {
        let outputItem = NSExtensionItem()
        // Complete implementation by setting the appropriate value on the output item
    
        let outputItems = [outputItem]
        self.extensionContext!.completeRequest(returningItems: outputItems, completionHandler: nil)
}

    @IBAction func cancel(_ sender: AnyObject?) {
        let cancelError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        self.extensionContext!.cancelRequest(withError: cancelError)
    }

}

extension NSUserInterfaceItemIdentifier {
    static let labelColumn = NSUserInterfaceItemIdentifier("LabelColumn")
//    static let button = NSUserInterfaceItemIdentifier("Button")
    static let labelIdentifier = NSUserInterfaceItemIdentifier("LabelIdentifier")
    
//    static let buttonColumn = NSUserInterfaceItemIdentifier("ButtonColumn")
//    static let buttonIdentifier = NSUserInterfaceItemIdentifier("ButtonIdentifier")
}
