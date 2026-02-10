//
//  SftpFileSystem.swift
//  Soduto
//
//  Created by Giedrius on 2017-04-22.
//  Copyright © 2017 Soduto. All rights reserved.
//

import Foundation
import os
import Cocoa
import UniformTypeIdentifiers
import Citadel
import NIOCore

// MARK: - Session Pool Actor

/// An actor that manages a pool of SSH/SFTP connections for concurrent operations.
/// Uses a semaphore-like pattern with async/await for thread-safe session management.
private actor SftpSessionPool {
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let poolSize: Int
    
    private var sessions: [SFTPClient] = []
    private var waiters: [CheckedContinuation<SFTPClient, Error>] = []
    private var isShuttingDown = false
    
    init(host: String, port: Int, user: String, password: String, poolSize: Int) async throws {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.poolSize = poolSize
        
        // Create initial sessions
        for i in 0..<poolSize {
            do {
                let session = try await Self.createSession(host: host, port: port, user: user, password: password)
                sessions.append(session)
                Logger.filesystem.debug("Session pool: Created initial session \(i + 1, privacy: .public)/\(poolSize, privacy: .public)")
            } catch {
                Logger.filesystem.error("Session pool: Failed to create initial session \(i + 1, privacy: .public)/\(poolSize, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Continue with smaller pool
            }
        }
        
        Logger.filesystem.debug("Session pool initialized with \(self.sessions.count, privacy: .public) sessions")
    }
    
    private static func createSession(host: String, port: Int, user: String, password: String) async throws -> SFTPClient {
        let ssh = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .passwordBased(username: user, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        return try await ssh.openSFTP()
    }
    
    /// Acquire a session from the pool. Suspends if none available.
    func acquire() async throws -> SFTPClient {
        if isShuttingDown {
            throw SftpFileSystem.SftpError.connectionFailed
        }
        
        // If we have an available session, return it
        if !sessions.isEmpty {
            let session = sessions.removeFirst()
            if session.isActive {
                Logger.filesystem.debug("Session pool: Acquired session. Remaining: \(self.sessions.count, privacy: .public)")
                return session
            } else {
                // Session died, try to get another or create new
                Logger.filesystem.debug("Session pool: Found dead session, discarding")
                return try await acquire()
            }
        }
        
        // No sessions available, wait for one
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            Logger.filesystem.debug("Session pool: No sessions available, waiting. Waiters: \(self.waiters.count, privacy: .public)")
        }
    }
    
    /// Release a session back to the pool.
    func release(_ session: SFTPClient) {
        guard !isShuttingDown else {
            Task { try? await session.close() }
            return
        }
        
        // If there are waiters, give them the session directly
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if session.isActive {
                waiter.resume(returning: session)
                Logger.filesystem.debug("Session pool: Released session to waiter. Waiters remaining: \(self.waiters.count, privacy: .public)")
            } else {
                // Session is dead, create a new one for the waiter
                Task {
                    do {
                        let newSession = try await Self.createSession(host: host, port: port, user: user, password: password)
                        waiter.resume(returning: newSession)
                    } catch {
                        waiter.resume(throwing: error)
                    }
                }
            }
            return
        }
        
        // No waiters, return to pool if healthy
        if session.isActive {
            sessions.append(session)
            Logger.filesystem.debug("Session pool: Released session. Pool size: \(self.sessions.count, privacy: .public)")
        } else {
            // Replace dead session
            Logger.filesystem.debug("Session pool: Session dead, creating replacement")
            Task {
                do {
                    let newSession = try await Self.createSession(host: host, port: port, user: user, password: password)
                    await self.addSession(newSession)
                } catch {
                    Logger.filesystem.error("Session pool: Failed to create replacement session: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
    
    private func addSession(_ session: SFTPClient) async {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume(returning: session)
        } else {
            sessions.append(session)
        }
    }
    
    /// Shutdown the pool and close all sessions.
    func shutdown() async {
        isShuttingDown = true
        
        // Fail all waiters
        for waiter in waiters {
            waiter.resume(throwing: SftpFileSystem.SftpError.connectionFailed)
        }
        waiters.removeAll()
        
        // Close all sessions
        for session in sessions {
            try? await session.close()
        }
        sessions.removeAll()
        
        Logger.filesystem.debug("Session pool: Shutdown complete")
    }
}

// MARK: - SftpFileSystem

class SftpFileSystem: NSObject, FileSystem {
    private let thumbnailConcurrentOperationCount = 16
    private let thumbnailSessionPoolSize = 6
    
    // MARK: Types
    
    enum SftpError: Error {
        case connectionFailed
        case authenticationFailed
        case sftpInitializationFailed
        case channelInitializationFailed
        case rootUrlInitializationFailed
        case invalidDirectoryContent(at: URL)
        case deletingFileFailed(at: URL)
        case copyingFileFailed(from: URL, to: URL)
        case movingFileFailed(from: URL, to: URL)
        case regularFileInsteadOfDirectory(at: URL)
        case downloadingFileFailed(at: URL)
        case creatingDirectoryFailed(at: URL)
        case openInputStreamFailed(at: URL)
        case openOutputStreamFailed(at: URL)
        case operationCancelled
    }
    
    // MARK: Properties
    
    weak var delegate: FileSystemDelegate?
    
    let name: String
    let rootUrl: URL
    let places: [Place] = []
    
    private let browseQueue = OperationQueue()
    private let fileOperationsQueue = OperationQueue()
    private let thumbnailQueue = OperationQueue()
    
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    
    // Main SFTP clients for browsing and file operations
    private var browseClient: SFTPClient?
    private var fileOperationsClient: SFTPClient?
    
    // Session pool for thumbnail downloads
    private var thumbnailPool: SftpSessionPool?
    
    // A dictionary to track ongoing and queued download operations by their URL.
    private var downloadTasks: [URL: Operation] = [:]
    // A lock to make the downloadTasks dictionary thread-safe.
    private let downloadTasksLock = NSLock()
    
    // MARK: Setup / Cleanup
    
    init(name: String, host: String, port: UInt16?, user: String, password: String, path: String) async throws {
        self.name = name
        self.host = host
        self.port = Int(port ?? 22)
        self.user = user
        self.password = password
        
        let directoryPath = path.hasSuffix("/") ? path : path + "/"
        guard let rootUrl = URL.url(scheme: "sftp", host: host, port: port, user: user, path: directoryPath) else {
            throw SftpError.rootUrlInitializationFailed
        }
        self.rootUrl = rootUrl
        
        self.browseQueue.maxConcurrentOperationCount = 1
        self.browseQueue.qualityOfService = .userInteractive
        self.fileOperationsQueue.maxConcurrentOperationCount = 1
        self.fileOperationsQueue.qualityOfService = .userInitiated
        self.thumbnailQueue.maxConcurrentOperationCount = thumbnailConcurrentOperationCount
        self.thumbnailQueue.qualityOfService = .utility
        
        super.init()
        
        // Initialize SSH connections
        Logger.filesystem.debug("Connecting to SFTP server at \(host, privacy: .public):\(self.port, privacy: .public)")
        
        self.browseClient = try await Self.createSftpClient(host: host, port: self.port, user: user, password: password)
        self.fileOperationsClient = try await Self.createSftpClient(host: host, port: self.port, user: user, password: password)
        
        Logger.filesystem.debug("Main SFTP clients connected")
        
        // Initialize thumbnail session pool
        self.thumbnailPool = try await SftpSessionPool(
            host: host,
            port: self.port,
            user: user,
            password: password,
            poolSize: thumbnailSessionPoolSize
        )
        
        Logger.filesystem.debug("SftpFileSystem initialization complete")
    }
    
    deinit {
        Logger.filesystem.debug("SftpFileSystem deinit: Cancelling all operations and closing connections")
        thumbnailQueue.cancelAllOperations()
        
        // Close clients in a detached task since deinit can't be async
        let browseClient = self.browseClient
        let fileOpsClient = self.fileOperationsClient
        let pool = self.thumbnailPool
        
        Task.detached {
            try? await browseClient?.close()
            try? await fileOpsClient?.close()
            await pool?.shutdown()
        }
    }
    
    private static func createSftpClient(host: String, port: Int, user: String, password: String) async throws -> SFTPClient {
        let ssh = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .passwordBased(username: user, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        return try await ssh.openSFTP()
    }
    
    // MARK: FileSystem
    
    func load(_ url: URL, completionHandler: @escaping (([FileItem]?, Int64?, Error?) -> Void)) {
        assert(isUnderRoot(url) || url == self.rootUrl, "URL (\(url)) is outside root tree (\(self.rootUrl)).")
        
        browseQueue.addOperation { [weak self] in
            guard let self = self, let client = self.browseClient else {
                DispatchQueue.main.async { completionHandler(nil, nil, SftpError.connectionFailed) }
                return
            }
            
            Task {
                do {
                    let contents = try await client.listDirectory(atPath: url.path)
                    let fileItems = contents.flatMap { name -> [FileItem] in
                        name.components.compactMap { component in
                            FileItem(sftpComponent: component, parentUrl: url)
                        }
                    }.sorted { lhs, rhs in
                        // Directories first, then sort by name (case-insensitive)
                        if lhs.isDirectory != rhs.isDirectory {
                            return lhs.isDirectory
                        }
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
                    // Free space not available through Citadel SFTP
                    await MainActor.run { completionHandler(fileItems, nil, nil) }
                } catch {
                    Logger.filesystem.error("Failed to list directory \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    await MainActor.run { completionHandler(nil, nil, error) }
                }
            }
        }
    }
    
    func delete(_ url: URL) -> FileOperation {
        _ = canDelete(url, assertOnFailure: true)
        
        let operation = FileOperation(operation: .delete, source: url)
        operation.sourceState = .inProgress
        operation.addExecutionBlock { [weak self] in
            guard let self = self, let client = self.fileOperationsClient else {
                operation.error = SftpError.connectionFailed
                operation.sourceState = .present
                return
            }
            
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    try await self.deleteRemote(at: url, using: client)
                    operation.sourceState = .deleted
                } catch {
                    operation.error = error
                    operation.sourceState = .present
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
        self.fileOperationsQueue.addOperation(operation)
        return operation
    }
    
    func copy(_ srcUrl: URL, to destUrl: URL) -> FileOperation {
        _ = canCopy(srcUrl, to: destUrl, assertOnFailure: true)
        
        let operation = FileOperation(operation: .copy, source: srcUrl, destination: destUrl)
        operation.destinationState = .inProgress
        operation.addExecutionBlock { [weak self] in
            guard let self = self, let client = self.fileOperationsClient else {
                operation.error = SftpError.connectionFailed
                operation.destinationState = .deleted
                return
            }
            
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    let finalDestUrl = try await self.nonExistingUrl(for: destUrl, using: client)
                    operation.destination = finalDestUrl
                    self.willAddFile(at: finalDestUrl, from: operation)
                    
                    if self.isUnderRoot(srcUrl) && self.isUnderRoot(finalDestUrl) {
                        // Remote to remote copy: read then write
                        try await self.copyRemoteToRemote(from: srcUrl, to: finalDestUrl, using: client, isCancelled: { operation.isCancelled })
                    } else if self.isUnderRoot(srcUrl) {
                        // Download from remote
                        try await self.download(from: srcUrl, to: finalDestUrl, using: client, isCancelled: { operation.isCancelled })
                    } else if self.isUnderRoot(finalDestUrl) {
                        // Upload to remote
                        try await self.upload(from: srcUrl, to: finalDestUrl, using: client, isCancelled: { operation.isCancelled })
                    }
                    operation.destinationState = .present
                } catch {
                    operation.error = error
                    operation.destinationState = .deleted
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
        self.fileOperationsQueue.addOperation(operation)
        return operation
    }
    
    func move(_ srcUrl: URL, to destUrl: URL) -> FileOperation {
        _ = canMove(srcUrl, to: destUrl, assertOnFailure: true)
        
        let operation = FileOperation(operation: .move, source: srcUrl, destination: destUrl)
        operation.sourceState = .inProgress
        operation.destinationState = .inProgress
        operation.addExecutionBlock { [weak self] in
            guard let self = self, let client = self.fileOperationsClient else {
                operation.error = SftpError.connectionFailed
                operation.sourceState = .present
                operation.destinationState = .deleted
                return
            }
            
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    let finalDestUrl = try await self.nonExistingUrl(for: destUrl, using: client)
                    operation.destination = finalDestUrl
                    self.willAddFile(at: finalDestUrl, from: operation)
                    
                    try await client.rename(at: srcUrl.path, to: finalDestUrl.path)
                    operation.sourceState = .deleted
                    operation.destinationState = .present
                } catch {
                    operation.error = error
                    operation.sourceState = .present
                    operation.destinationState = .deleted
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
        self.fileOperationsQueue.addOperation(operation)
        return operation
    }
    
    func createFolder(_ url: URL) -> FileOperation {
        _ = canCreateFolder(url, assertOnFailure: true)
        
        let operation = FileOperation(operation: .createFolder, destination: url)
        operation.destinationState = .inProgress
        operation.addExecutionBlock { [weak self] in
            guard let self = self, let client = self.fileOperationsClient else {
                operation.error = SftpError.connectionFailed
                operation.destinationState = .deleted
                return
            }
            
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    let finalUrl = try await self.nonExistingUrl(for: url, using: client)
                    operation.destination = finalUrl
                    self.willAddFile(at: finalUrl, from: operation)
                    
                    try await client.createDirectory(atPath: finalUrl.path)
                    operation.destinationState = .present
                } catch {
                    operation.error = error
                    operation.destinationState = .deleted
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
        self.fileOperationsQueue.addOperation(operation)
        return operation
    }
    
    // MARK: Private - Remote Operations
    
    /// Check if a remote path exists and return its attributes, or nil if it doesn't exist.
    private func getAttributesIfExists(at path: String, using client: SFTPClient) async -> SFTPFileAttributes? {
        do {
            return try await client.getAttributes(at: path)
        } catch {
            return nil
        }
    }
    
    /// Check if a remote file exists.
    private func fileExists(at path: String, using client: SFTPClient) async -> Bool {
        guard let attrs = await getAttributesIfExists(at: path, using: client) else { return false }
        // Check it's not a directory
        return attrs.permissions.map { $0 & 0o40000 == 0 } ?? true
    }
    
    /// Check if a remote directory exists.
    private func directoryExists(at path: String, using client: SFTPClient) async -> Bool {
        guard let attrs = await getAttributesIfExists(at: path, using: client) else { return false }
        // Check it's a directory
        return attrs.permissions.map { $0 & 0o40000 != 0 } ?? false
    }
    
    /// Return the same given URL or an alternative that does not yet exist.
    private func nonExistingUrl(for url: URL, using client: SFTPClient) async throws -> URL {
        var url = url
        
        if isUnderRoot(url) {
            while await remotePathExists(at: url.regularFileURL.path, using: client) {
                url = url.alternativeForDuplicate()
            }
            return url
        } else if url.isFileURL {
            while FileManager.default.fileExists(atPath: url.regularFileURL.path) {
                url = url.alternativeForDuplicate()
            }
            return url
        } else {
            throw FileSystemError.invalidUrl(url: url)
        }
    }
    
    /// Check if a remote path exists (either file or directory).
    private func remotePathExists(at path: String, using client: SFTPClient) async -> Bool {
        return await getAttributesIfExists(at: path, using: client) != nil
    }
    
    /// Delete a remote file or directory.
    private func deleteRemote(at url: URL, using client: SFTPClient) async throws {
        assert(isUnderRoot(url), "URL being deleted (\(url)) expected to be under root (\(self.rootUrl)).")
        
        if url.hasDirectoryPath {
            try await deleteRemoteDirectory(at: url, using: client)
        } else {
            try await client.remove(at: url.path)
        }
    }
    
    /// Delete a possibly non-empty remote directory.
    private func deleteRemoteDirectory(at url: URL, using client: SFTPClient) async throws {
        assert(isUnderRoot(url), "URL being deleted (\(url)) expected to be under root (\(self.rootUrl)).")
        assert(url.hasDirectoryPath, "URL being deleted (\(url)) expected to be a directory.")
        
        // First try to delete directly (works for empty directories)
        do {
            try await client.rmdir(at: url.path)
            return
        } catch {
            // May fail on non-empty directory, try recursive delete
        }
        
        // List and delete children
        let contents = try await client.listDirectory(atPath: url.path)
        for name in contents {
            for component in name.components {
                let filename = component.filename
                guard filename != "." && filename != ".." else { continue }
                let isDir = component.attributes.permissions.map { $0 & 0o40000 != 0 } ?? false
                let fileUrl = url.appendingPathComponent(filename, isDirectory: isDir)
                try await deleteRemote(at: fileUrl, using: client)
            }
        }
        
        // Try again to delete now-empty directory
        try await client.rmdir(at: url.path)
    }
    
    /// Copy a remote file to another remote location (read + write).
    private func copyRemoteToRemote(from srcUrl: URL, to destUrl: URL, using client: SFTPClient, isCancelled: @escaping () -> Bool) async throws {
        if srcUrl.hasDirectoryPath {
            // Create destination directory
            try await client.createDirectory(atPath: destUrl.path)
            
            // Copy children
            let contents = try await client.listDirectory(atPath: srcUrl.path)
            for name in contents {
                for component in name.components {
                    let filename = component.filename
                    guard filename != "." && filename != ".." else { continue }
                    if isCancelled() { throw SftpError.operationCancelled }
                    
                    let isDir = component.attributes.permissions.map { $0 & 0o40000 != 0 } ?? false
                    let fileSrcUrl = srcUrl.appendingPathComponent(filename, isDirectory: isDir)
                    let fileDestUrl = destUrl.appendingPathComponent(filename, isDirectory: isDir)
                    try await copyRemoteToRemote(from: fileSrcUrl, to: fileDestUrl, using: client, isCancelled: isCancelled)
                }
            }
        } else {
            // Read source file
            let data = try await client.withFile(filePath: srcUrl.path, flags: .read) { file in
                try await file.readAll()
            }
            
            if isCancelled() { throw SftpError.operationCancelled }
            
            // Write to destination
            try await client.withFile(filePath: destUrl.path, flags: [.write, .create, .truncate]) { file in
                try await file.write(data)
            }
        }
    }
    
    /// Download a remote file or directory to a local destination.
    private func download(from srcUrl: URL, to destUrl: URL, using client: SFTPClient, isCancelled: @escaping () -> Bool) async throws {
        assert(isUnderRoot(srcUrl), "Source URL (\(srcUrl)) expected to be under root (\(self.rootUrl)).")
        assert(destUrl.isFileURL, "Destination URL (\(destUrl)) expected to be local URL.")
        
        if srcUrl.hasDirectoryPath {
            try await downloadDirectory(from: srcUrl, to: destUrl, using: client, isCancelled: isCancelled)
        } else {
            let finalDestUrl = try await nonExistingUrl(for: destUrl, using: client)
            
            // Read remote file
            let data = try await client.withFile(filePath: srcUrl.path, flags: .read) { file in
                try await file.readAll()
            }
            
            if isCancelled() { throw SftpError.operationCancelled }
            
            // Write to local file
            let dataBytes = Data(buffer: data)
            try dataBytes.write(to: finalDestUrl)
        }
    }
    
    /// Download a remote directory to a local destination.
    private func downloadDirectory(from srcUrl: URL, to destUrl: URL, using client: SFTPClient, isCancelled: @escaping () -> Bool) async throws {
        // Create local directory
        try FileManager.default.createDirectory(at: destUrl, withIntermediateDirectories: true, attributes: nil)
        
        // List and download children
        let contents = try await client.listDirectory(atPath: srcUrl.path)
        for name in contents {
            for component in name.components {
                let filename = component.filename
                guard filename != "." && filename != ".." else { continue }
                if isCancelled() { throw SftpError.operationCancelled }
                
                let isDir = component.attributes.permissions.map { $0 & 0o40000 != 0 } ?? false
                let fileSrcUrl = srcUrl.appendingPathComponent(filename, isDirectory: isDir)
                let fileDestUrl = destUrl.appendingPathComponent(filename, isDirectory: isDir)
                try await download(from: fileSrcUrl, to: fileDestUrl, using: client, isCancelled: isCancelled)
            }
        }
    }
    
    /// Upload a local file or directory to a remote destination.
    private func upload(from srcUrl: URL, to destUrl: URL, using client: SFTPClient, isCancelled: @escaping () -> Bool) async throws {
        assert(srcUrl.isFileURL, "Source URL (\(srcUrl)) expected to be local URL.")
        assert(isUnderRoot(destUrl), "Destination URL (\(destUrl)) expected to be under root (\(self.rootUrl)).")
        
        if srcUrl.hasDirectoryPath {
            try await uploadDirectory(from: srcUrl, to: destUrl, using: client, isCancelled: isCancelled)
        } else {
            let finalDestUrl = try await nonExistingUrl(for: destUrl, using: client)
            
            // Read local file
            let data = try Data(contentsOf: srcUrl)
            
            if isCancelled() { throw SftpError.operationCancelled }
            
            // Write to remote
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            let bufferToWrite = buffer
            try await client.withFile(filePath: finalDestUrl.path, flags: [.write, .create, .truncate]) { file in
                try await file.write(bufferToWrite)
            }
        }
    }
    
    /// Upload a local directory to a remote destination.
    private func uploadDirectory(from srcUrl: URL, to destUrl: URL, using client: SFTPClient, isCancelled: @escaping () -> Bool) async throws {
        // Create remote directory
        try await client.createDirectory(atPath: destUrl.path)
        
        // List and upload children
        let contents = try FileManager.default.contentsOfDirectory(at: srcUrl, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants, .skipsSubdirectoryDescendants])
        
        for fileSrcUrl in contents {
            if isCancelled() { throw SftpError.operationCancelled }
            let fileDestUrl = fileSrcUrl.movedTo(destUrl)
            try await upload(from: fileSrcUrl, to: fileDestUrl, using: client, isCancelled: isCancelled)
        }
    }
    
    /// Perform notification about starting to add new file.
    private func willAddFile(at url: URL, from fileOperation: FileOperation) {
        DispatchQueue.main.async {
            self.delegate?.fileSystem(self, willAddFileAt: url, from: fileOperation)
        }
    }
    
    // MARK: Data Loading (Thumbnails)
    
    func loadData(at url: URL, completionHandler: @escaping ((Data?, Error?) -> Void)) {
        assert(isUnderRoot(url), "URL (\(url)) is outside root tree (\(self.rootUrl)).")
        
        // Task Duplicate Check
        downloadTasksLock.lock()
        if downloadTasks[url] != nil {
            downloadTasksLock.unlock()
            Logger.filesystem.debug("SftpFileSystem loadData: Download for \(url.lastPathComponent, privacy: .public) is already queued. Skipping.")
            return
        }
        downloadTasksLock.unlock()
        
        let opCount = thumbnailQueue.operationCount
        Logger.filesystem.debug(">>> QUEUEING operation for \(url.lastPathComponent, privacy: .public). Current queue size: \(opCount, privacy: .public)")
        
        let operation = BlockOperation()
        
        operation.addExecutionBlock { [weak self, weak operation] in
            Logger.filesystem.debug(">>> STARTING operation for \(url.lastPathComponent, privacy: .public).")
            
            guard let self = self, let strongOperation = operation, !strongOperation.isCancelled else {
                Logger.filesystem.debug("SftpFileSystem loadData: Operation was nil or cancelled before starting for \(url.lastPathComponent, privacy: .public).")
                DispatchQueue.main.async { completionHandler(nil, nil) }
                return
            }
            
            guard let pool = self.thumbnailPool else {
                DispatchQueue.main.async { completionHandler(nil, SftpError.connectionFailed) }
                return
            }
            
            let semaphore = DispatchSemaphore(value: 0)
            
            Task {
                var session: SFTPClient?
                var resultData: Data?
                var resultError: Error?
                
                defer {
                    // Return session to pool
                    if let session = session {
                        Task { await pool.release(session) }
                    }
                    semaphore.signal()
                }
                
                do {
                    session = try await pool.acquire()
                    
                    if strongOperation.isCancelled {
                        Logger.filesystem.debug("SftpFileSystem loadData: Operation cancelled after acquiring session for \(url.lastPathComponent, privacy: .public).")
                        return
                    }
                    
                    Logger.filesystem.debug("SftpFileSystem loadData: Download starting for \(url.lastPathComponent, privacy: .public).")
                    
                    let buffer = try await session!.withFile(filePath: url.path, flags: .read) { file in
                        try await file.readAll()
                    }
                    
                    if strongOperation.isCancelled {
                        Logger.filesystem.debug("SftpFileSystem loadData: Operation cancelled after download for \(url.lastPathComponent, privacy: .public).")
                        return
                    }
                    
                    resultData = Data(buffer: buffer)
                    Logger.filesystem.debug("SftpFileSystem loadData: Download complete. \(resultData?.count ?? 0, privacy: .public) bytes for \(url.lastPathComponent, privacy: .public).")
                    
                } catch {
                    if !strongOperation.isCancelled {
                        resultError = error
                        Logger.filesystem.error("SftpFileSystem loadData: Download failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                
                if !strongOperation.isCancelled {
                    let data = resultData
                    let error = resultError
                    await MainActor.run { completionHandler(data, error) }
                } else {
                    await MainActor.run { completionHandler(nil, nil) }
                }
            }
            
            semaphore.wait()
            Logger.filesystem.debug("SftpFileSystem loadData: <<< Operation FINISHED for \(url.lastPathComponent, privacy: .public) >>>")
        }
        
        operation.completionBlock = { [weak self] in
            self?.downloadTasksLock.lock()
            self?.downloadTasks.removeValue(forKey: url)
            Logger.filesystem.debug("SftpFileSystem: Removed task for \(url.lastPathComponent, privacy: .public) from tracking. Remaining: \(self?.downloadTasks.count ?? 0, privacy: .public)")
            self?.downloadTasksLock.unlock()
        }
        
        // Add the operation to the tracking dictionary before queueing it.
        downloadTasksLock.lock()
        downloadTasks[url] = operation
        downloadTasksLock.unlock()
        
        thumbnailQueue.addOperation(operation)
    }
    
    /// Cancels any queued or ongoing thumbnail download for the specified URL.
    public func cancelLoad(for url: URL) {
        downloadTasksLock.lock()
        defer { downloadTasksLock.unlock() }
        
        if let operation = downloadTasks[url] {
            if !operation.isFinished && !operation.isCancelled {
                operation.cancel()
                Logger.filesystem.debug("SftpFileSystem: Cancel request for \(url.lastPathComponent, privacy: .public).")
            }
        }
    }
}


// MARK: - FileItem Extension for Citadel

extension FileItem {
    
    fileprivate convenience init?(sftpComponent: SFTPPathComponent, parentUrl: URL) {
        var name = sftpComponent.filename
        guard name != "." && name != ".." else { return nil }
        if name.hasSuffix("/") { name = String(name.dropLast()) }
        
        let attrs = sftpComponent.attributes
        let isDir = attrs.permissions.map { $0 & 0o40000 != 0 } ?? false
        
        let url = parentUrl.appendingPathComponent(name, isDirectory: isDir)
        
        var flags: Flags = [.isReadable, .isWritable] // Assume readable/writable
        if isDir { flags.insert(.isDirectory) }
        if name.hasPrefix(".") { flags.insert(.isHidden) }
        
        let fileType = flags.contains(.isDirectory) ? UTType.folder : UTType(filenameExtension: url.pathExtension) ?? .data
        let icon = NSWorkspace.shared.icon(for: fileType)
        
        let fileSize = Int64(attrs.size ?? 0)
        
        let modate: Date? = attrs.accessModificationTime?.modificationTime
        
        self.init(url: url, name: name, icon: icon, flags: flags, fileSize: fileSize, modate: modate)
    }
}
