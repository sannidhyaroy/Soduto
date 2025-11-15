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
    public weak var imageLoader: ImageLoader?

    private var currentLoadingURL: URL?
    private var retryTimer: Timer?
    private let imageExtensions = ["jpg", "jpeg", "png", "heic", "gif", "bmp", "webp"]
    private let maxThumbnailFileSize: UInt64 = 50*1024*1024 // 50MB
    
    public var iconView: IconItemView? { return self.view as? IconItemView }
    
    public var fileItem: FileItem? {
        didSet {
            guard isViewLoaded else { return }

            retryTimer?.invalidate()
            retryTimer = nil

            // Cancel the request for the previous FileItem this cell represented.
            if let oldUrl = oldValue?.url, oldUrl != fileItem?.url {
                imageLoader?.cancelLoad(for: oldUrl)
            }

            // Cancel any pending request for this cell instance before assigning a new one.
            if let pendingUrl = self.currentLoadingURL {
                imageLoader?.cancelLoad(for: pendingUrl)
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

                // Check if thumbnails should be displayed

                // 1. extension
                guard imageExtensions.contains(ext) else {
                    return
                }

                // 2. not directory
                guard !fileItem.isDirectory else {
                    return
                }

                // 3. file size > 0
                guard fileItem.fileSize > 0 else {
                    Log.debug?.message("IconItem: Skipping thumbnail for \(fileItem.name) (size 0)")
                    return
                }

                // 4. file size < max
                guard fileItem.fileSize <= maxThumbnailFileSize else {
                    Log.debug?.message("IconItem: Skipping thumbnail for \(fileItem.name) (size \(fileItem.fileSize) exceeds limit)")
                    return
                }

                Log.debug?.message("IconItem: Requesting thumbnail for \(fileItem.name)")
                loadThumbnail(for: fileItem)

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

        // Invalidate any pending retry, as we are starting a new load.
        retryTimer?.invalidate()
        retryTimer = nil

        Log.debug?.message("IconItem loadThumbnail: Loading data for \(urlToLoad.lastPathComponent)")

        // Request the SftpFileSystem to load the raw data for the file URL.
        // This is an async operation.
        imageLoader?.loadThumbnail(for: urlToLoad) { [weak self] (image, error) in
            // This is the completion handler.
            // It runs on the main thread when the download/resize is finished or has failed.

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

            if let image = image {
                // Success: we got an NSImage.
                Log.debug?.message("IconItem loadThumbnail success: Set thumbnail for \(urlToLoad.lastPathComponent)")
                self.imageView?.image = image
            } else if let error = error {
                let isRetryable: Bool

                if let imageLoaderError = error as? ImageLoaderError {
                    switch imageLoaderError {
                    case .downloadFailed:
                        isRetryable = true
                    case .resizeFailed:
                        isRetryable = false
                    }
                } else {
                  isRetryable = false
                  Log.debug?.message("IconItem loadThumbnail: Received unknown error type. Not retrying.")
                }

                if isRetryable {
                     Log.debug?.message("""
                        IconItem loadThumbnail FAILED (Retryable) for \(urlToLoad.lastPathComponent). Scheduling retry.
                        Error: \(error.localizedDescription)
                        """)
                    self.scheduleRetry(for: fileItem)
                } else {
                    Log.debug?.message("""
                        IconItem loadThumbnail FAILED (Non-retryable) for \(urlToLoad.lastPathComponent).
                        Error: \(error.localizedDescription)
                        """)
                }
            } else {
                // Not Hard Failure: just a cancel. (image == nil && error == nil)
                Log.debug?.message(
                    "IconItem loadThumbnail cancelled for \(urlToLoad.lastPathComponent)")
            }
        }
    }

    /**
     Schedules a retry attempt after a short delay.
     */
    private func scheduleRetry(for fileItem: FileItem) {
        retryTimer?.invalidate() // Invalidate previous timer just in case

        retryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }

            // Check if we *still* care about this item before retrying
            guard self.fileItem?.url == fileItem.url else {
                Log.debug?.message("IconItem: Retry timer fired, but cell was reused. Cancelling retry.")
                return
            }

            Log.debug?.message("IconItem: Retry timer fired. Retrying load for \(fileItem.name).")
            self.loadThumbnail(for: fileItem)
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
        retryTimer?.invalidate()
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
