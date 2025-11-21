// ImageLoader.swift
import Cocoa
import CleanroomLogger
import ImageIO

public enum ImageLoaderError: Error {
    case downloadFailed(Error)
    case resizeFailed
}

/**
 Manages loading, resizing, and in-memory caching of thumbnails.
 This class is thread-safe.
 */
public class ImageLoader {
    
    // MARK: Properties
    
    private let fileSystem: SftpFileSystem
    
    // Cache for resized NSImage objects.
    private let imageCache = NSCache<NSURL, NSImage>()
    
    // A dedicated queue for CPU-intensive image resizing operations.
    private let resizeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.soduto.ImageResizeQueue"
        queue.qualityOfService = .utility
        // Allow parallel resizing, similar to our download queue
        queue.maxConcurrentOperationCount = 16 
        return queue
    }()
    
    // Tracks completion handlers for in-flight requests to avoid duplicate downloads.
    private var completionHandlers = [URL: [(image: NSImage?, error: Error?) -> Void]]()
    private let lock = NSLock()
    
    // MARK: Constants
    
    // The target size for all thumbnails.
    // Use a bit larger than the UI needs for good quality.
    private static let ThumbnailSize = CGSize(width: 256, height: 256)

    // MARK: Init
    
    init(fileSystem: SftpFileSystem) {
        self.fileSystem = fileSystem
    }
    
    // MARK: Public Methods

    /**
     Asynchronously loads and provides a resized thumbnail for a given URL.
     - Checks memory cache.
     - If not cached, triggers a download via SftpFileSystem.
     - Resizes the downloaded image off the main thread.
     - Caches the resized image and calls all pending completion handlers.
     */
    public func loadThumbnail(for url: URL, completion: @escaping (_ image: NSImage?, _ error: Error?) -> Void) {
        // 1. Check cache first
        if let cachedImage = imageCache.object(forKey: url as NSURL) {
            Log.debug?.message("ImageLoader: Cache HIT for \(url.lastPathComponent)")
            completion(cachedImage, nil)
            return
        }

        Log.debug?.message("ImageLoader: Cache MISS for \(url.lastPathComponent)")

        lock.lock()
        let handlerCount = completionHandlers[url]?.count ?? 0
        Log.debug?.message(">>> ImageLoader: Requesting download for \(url.lastPathComponent). In-flight handlers: \(handlerCount)")

        // 2. Check for in-flight requests
        if var handlers = completionHandlers[url] {
            // Request is already running, just add our completion handler
            handlers.append(completion)
            completionHandlers[url] = handlers
            lock.unlock()
            Log.debug?.message("ImageLoader: Piggybacking request for \(url.lastPathComponent).")
            return
        }

        // 3. New request. Store handler and start download.
        completionHandlers[url] = [completion]
        lock.unlock()

        fileSystem.loadData(at: url) { [weak self] (data, error) in
            guard let self = self else { return }

            // This completion comes from SftpFileSystem and is on the main thread.

            guard let data = data, error == nil else {
                let returnError: Error? = (error != nil) ? ImageLoaderError.downloadFailed(error!) : nil
                Log.debug?.message("ImageLoader: Download failed. Error: \(error?.localizedDescription ?? "nil")")
                // Notify handlers with failure/cancel status
                self.notifyHandlers(for: url, with: nil, error: returnError)
                return
            }

            let resizeOpCount = self.resizeQueue.operationCount
            Log.debug?.message(">>> RESIZE QUEUE: Adding resize for \(url.lastPathComponent). Current resize queue size: \(resizeOpCount)")

            // 4. Download complete, now resize off the main thread.
            self.resizeQueue.addOperation {
                let resizedImage = self.resizeImage(from: data, targetSize: Self.ThumbnailSize)

                if let resizedImage = resizedImage {
                    Log.debug?.message("ImageLoader: Resize success for \(url.lastPathComponent).")
                    // Store in memory cache
                    self.imageCache.setObject(resizedImage, forKey: url as NSURL)
                    // 5. Notify all original requesters (on main thread)
                    self.notifyHandlers(for: url, with: resizedImage, error: nil)
                } else {
                    Log.debug?.message("ImageLoader: Resize FAILED for \(url.lastPathComponent).")
                    // 5. Notify resize failure
                    self.notifyHandlers(for: url, with: nil, error: ImageLoaderError.resizeFailed)
                }
            }
        }
    }
    
    /**
     Requests cancellation of a download operation.
     */
    public func cancelLoad(for url: URL) {
        Log.debug?.message("ImageLoader: Requesting cancel for \(url.lastPathComponent)")
        // This will cancel the download.
        fileSystem.cancelLoad(for: url)
        
        // Note: The SftpFileSystem.loadData completion *must*
        // still fire (with nil data) to clean up handlers.
    }

    // MARK: Private Helpers

    /**
     Notifies all waiting completion handlers for a given URL.
     This method is thread-safe.
     */
    private func notifyHandlers(for url: URL, with image: NSImage?, error: Error?) {
        lock.lock()
        // Get and remove all handlers for this URL
        let handlers = completionHandlers.removeValue(forKey: url) ?? []
        lock.unlock()

        Log.debug?.message("ImageLoader: Notifying \(handlers.count) handlers for \(url.lastPathComponent).")

        // Call them back on the main thread
        DispatchQueue.main.async {
            handlers.forEach { $0(image, error) }
        }
    }

    /**
     Resizes an image from data to a target size.
     This is a CPU-intensive operation and should be run on a background queue.
     */
    private func resizeImage(from data: Data, targetSize: CGSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let maxPixelSize = max(targetSize.width, targetSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let thumbnailCGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let width = CGFloat(thumbnailCGImage.width)
        let height = CGFloat(thumbnailCGImage.height)

        return NSImage(cgImage: thumbnailCGImage, size: NSSize(width: width, height: height))
    }
}
