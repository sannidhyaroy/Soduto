//
//  IconViewItem.swift
//  Soduto
//
//  Created by Giedrius on 2017-03-05.
//  Copyright © 2017 Soduto. All rights reserved.
//

import Cocoa
import CleanroomLogger

public protocol IconItemDelegate: class {
    func iconItem(_ iconItem: IconItem, didChangeName: String)
}

public class IconItem: NSCollectionViewItem {
    
    // MARK: Properties
    
    public weak var delegate: IconItemDelegate?
    weak var fileSystem: FileSystem?

    private var currentLoadingURL: URL?
    private let imageExtensions = ["jpg", "jpeg", "png", "heic", "gif", "bmp", "webp"]
    
    public var iconView: IconItemView? { return self.view as? IconItemView }
    
    public var fileItem: FileItem? {
        didSet {
            guard isViewLoaded else { return }

            // Cancel the request for the previous FileItem this cell represented.
            if let oldUrl = oldValue?.url, oldUrl != fileItem?.url {
                (self.fileSystem as? SftpFileSystem)?.cancelLoad(for: oldUrl)
            }

            // Cancel any pending request for this cell instance before assigning a new one.
            if let pendingUrl = self.currentLoadingURL {
                (self.fileSystem as? SftpFileSystem)?.cancelLoad(for: pendingUrl)
            }

            // This property observer is the entry point for updating the cell's view.
            // When a new FileItem model is set, we reset the view state.
            Log.debug?.message("IconItem fileItem.didSet: \(fileItem?.name ?? "nil")")

            // Clear any pending load operation for the previous item.
            currentLoadingURL = nil

            if let fileItem = self.fileItem, !fileItem.flags.contains(.isDeleted) {
                // Set default icon and text immediately.
                self.imageView?.image = fileItem.icon
                self.iconView?.label = fileItem.name
                self.iconView?.isHiddenItem = fileItem.flags.contains(.isHidden)
                self.iconView?.isBusy = fileItem.flags.contains(.isBusy)

                let ext = fileItem.url.pathExtension.lowercased()
                if imageExtensions.contains(ext) {
                    Log.debug?.message("IconItem: Requesting thumbnail for \(fileItem.name)")
                    loadThumbnail(for: fileItem)
                }

            } else {
                // The fileItem is nil or marked as deleted, clear the view.
                self.imageView?.image = nil
                self.iconView?.label = ""
                self.iconView?.isHiddenItem = false
                self.iconView?.isBusy = false
            }
        }
    }

    private func loadThumbnail(for fileItem: FileItem) {
        let urlToLoad = fileItem.url
        // Store the URL we are starting to load.
        self.currentLoadingURL = urlToLoad

        Log.debug?.message("IconItem loadThumbnail: Loading data for \(urlToLoad.lastPathComponent)")

        // Request the SftpFileSystem to load the raw data for the file URL.
        // This is an async operation.
        (self.fileSystem as? SftpFileSystem)?.loadData(at: urlToLoad) { [weak self] (data, error) in
            // This is the completion handler.
            // It runs on the main thread when the download is finished or has failed.

            guard let self = self else {
                // nill
                Log.debug?.message("""
                    IconItem loadThumbnail completion: self is nil.
                        Request was for \(urlToLoad.lastPathComponent).
                    """)
                return
            }

            guard self.currentLoadingURL == urlToLoad else {
                // It's too late
                Log.debug?.message("""
                    IconItem loadThumbnail completion: Stale request. Call reused.
                        Loaded \(urlToLoad.lastPathComponent) but current is 
                            \(self.currentLoadingURL?.lastPathComponent ?? "nil").
                    """)
                return
            }

            // We have the correct data for the current cell. Clear the loading URL.
            self.currentLoadingURL = nil

            if let data = data, let image = NSImage(data: data) {
                // Success: we got an NSImage.
                Log.debug?.message("IconItem loadThumbnail success: Set thumbnail for \(urlToLoad.lastPathComponent)")
                self.imageView?.image = image
            } else {
                // Failure: not downloaded or broken data.
                if let error = error {
                    Log.debug?.message(
                    "IconItem loadThumbnail failed for \(urlToLoad.lastPathComponent): \(error.localizedDescription)")
                } else {
                    Log.debug?.message("""
                    IconItem loadThumbnail failed: Received data for \(urlToLoad.lastPathComponent),
                        but it was not a valid image.
                    """)
                }
            }
        }
    }
    
    public override var isSelected: Bool {
        didSet {
            guard self.isSelected != oldValue else { return }
            updateViewSelection()
        }
    }
    
    public override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            guard self.highlightState != oldValue else { return }
            updateViewSelection()
        }
    }
    
    private func updateViewSelection() {
        self.iconView?.isSelected = self.isSelected || self.highlightState == .asDropTarget
    }
    
    
    // MARK: Setup / Cleanup
    
    deinit {
        cancelEditing()
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        self.view.wantsLayer = true
        (self.view as? IconItemView)?.collectionItem = self
    }
    
    
    // MARK: Editing
    
    public var isEditing: Bool { return self.iconView?.isEditing ?? false }
    
    public func startEditing() { self.iconView?.startEditing() }
    
    public func cancelEditing() { self.iconView?.cancelEditing() }
    
    /// Called by the view when edited text changes
    public func labelTextDidChange(_ text: String) {
        self.delegate?.iconItem(self, didChangeName: text)
        self.iconView?.cancelEditing()
    }
    
}
