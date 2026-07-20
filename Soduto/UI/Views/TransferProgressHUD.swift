//
//  TransferProgressHUD.swift
//  Soduto
//
//  Created by Sannidhya Roy on 07/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import SwiftUI

// MARK: - SpeedSample

/// A single (bytes, timestamp) data point for rolling speed calculation
struct SpeedSample: Sendable {
    var bytes: Int64
    var time: Date
}

// MARK: - TransferOutcome

/// Outcome of a completed file transfer
enum TransferOutcome: Sendable {
    case success
    case failed
    case cancelled
}

// MARK: - TransferProgressRecord

/// A single in-flight (or lingering) file transfer row within a device group
struct TransferProgressRecord: Identifiable, Sendable {
    let id: String
    /// Groups this row under the correct `DeviceGroup` in the store
    let deviceId: String
    let deviceName: String
    let deviceType: DeviceType
    var label: String
    let totalBytes: Int64?
    let isUpload: Bool
    var bytesTransferred: Int64 = 0
    /// Rolling speed samples capped to the last 10s by the store (used for ETA only)
    var speedSamples: [SpeedSample] = []
    var isCompleted: Bool = false
    var outcome: TransferOutcome?
    
    // MARK: Block-epoch speed display
    //
    // Speed is quantised into fixed 2-second blocks instead of a sliding window.
    // A sliding window causes the displayed value to jump whenever a large chunk
    // enters or exits the window boundary, even at steady throughput. Fixed blocks
    // have no edge artifacts: bytes accumulate monotonically within the block and
    // the display only changes at block boundaries (~every 2 s).
    //
    // `displaySpeedBytesPerSec` is nil until the first complete block fires,
    // then held until the next block ends. The UI reads this value; it never
    // reads `speedBytesPerSec` for display.
    
    /// Bytes transferred at the start of the current 2-second measurement block.
    var blockStartBytes: Int64 = 0
    /// Wall-clock time when the current block started. Nil until the first bytes arrive.
    var blockStartTime: Date? = nil
    /// Speed shown in the UI — updated once per 2-second block. Nil for the first block.
    var displaySpeedBytesPerSec: Double? = nil
    
    var fractionCompleted: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1.0, Double(bytesTransferred) / Double(total))
    }
    
    /// Smoothed speed over a trailing 5-second window (used for ETA only)
    var speedBytesPerSec: Double? {
        guard speedSamples.count >= 2 else { return nil }
        let last = speedSamples.last!
        let window = speedSamples.filter { $0.time >= last.time.addingTimeInterval(-5) }
        let first = window.count >= 2 ? window.first! : speedSamples.first!
        let dt = last.time.timeIntervalSince(first.time)
        guard dt > 0.1 else { return nil }
        let db = last.bytes - first.bytes
        guard db > 0 else { return nil }
        return Double(db) / dt
    }
    
    var etaSeconds: Double? {
        guard let total = totalBytes, total > 0,
              let speed = speedBytesPerSec, speed > 0 else { return nil }
        return Double(max(0, total - bytesTransferred)) / speed
    }
}

// MARK: - DeviceGroup

/// Groups all in-flight transfer rows from a single device under one collapsible section
struct DeviceGroup: Identifiable {
    /// The device ID — used as the stable identity for the group
    let id: String
    let deviceName: String
    let deviceType: DeviceType
    var records: [TransferProgressRecord]
    /// Collapse state: shown only when 2+ rows exist, default expanded
    var isExpanded: Bool = true
    
    // Eviction counters: incremented when a completed row evicts after linger. Split by direction
    // so the info bubble pills track upload/download totals independently
    var evictedUploadSuccesses: Int = 0
    var evictedUploadFailures: Int = 0
    var evictedDownloadSuccesses: Int = 0
    var evictedDownloadFailures: Int = 0
    
    /// Total files expected from the remote device (downloads only). Set by ShareService;
    /// grows if Android expands the batch. Used to show awaiting pill before packets arrive
    var expectedDownloads: Int = 0
}

// MARK: - Transfer Progress Store

@MainActor
final class TransferProgressStore: ObservableObject {
    @Published var groups: [DeviceGroup] = []
    
    /// Randomly chosen at the start of each HUD session
    private(set) var endMessage: String = TransferProgressStore.pickEndMessage()
    
    private static let endMessages = [
        // atmospheric
        "nothing more in transit",
        "the wire is quiet",
        "nothing lurking below",
        "nothing en route",
        "the ether is still",
        "nothing else waits to cross",
        "all flights have landed",
        "the current has stilled",
        "the channel breathes",
        "nothing else remains in flight",
        "the bridge stands empty",
        "the signal sleeps",
        "nothing crosses the void",
        "the antenna dreams",
        "wavelengths at rest",
        "the handshake dissolves",
        "the last byte has landed",
        "the pipeline dreams",
        // witty
        "and that's a wrap",
        "transferred and forgotten",
        "even the packets have gone home",
        "the bytes have left the building",
        "no bytes were harmed in this transfer",
        "sent. received. vanished.",
        "buffer empty, soul at peace",
        "you've reached the end of the queue",
        // nerdy
        "all quiet on the wireless front",
        "TCP says goodnight",
        "all ACKs received",
    ]
    
    private static func pickEndMessage() -> String { endMessages.randomElement()! }
    
    func refreshEndMessage() { endMessage = Self.pickEndMessage() }
    
    func add(_ record: TransferProgressRecord) {
        if let gi = groups.firstIndex(where: { $0.id == record.deviceId }) {
            groups[gi].records.removeAll { $0.id == record.id }
            groups[gi].records.append(record)
        } else {
            groups.append(DeviceGroup(
                id: record.deviceId,
                deviceName: record.deviceName,
                deviceType: record.deviceType,
                records: [record]
            ))
        }
    }
    
    func update(id: String, bytes: Int64) {
        for gi in groups.indices {
            guard let ri = groups[gi].records.firstIndex(where: { $0.id == id }) else { continue }
            groups[gi].records[ri].bytesTransferred = bytes
            let now = Date()
            
            // Rolling samples for ETA (trailing 10 s, capped at 20 points)
            var s = groups[gi].records[ri].speedSamples
            s.append(SpeedSample(bytes: bytes, time: now))
            s = s.filter { $0.time >= now.addingTimeInterval(-10) }
            if s.count > 20 { s.removeFirst(s.count - 20) }
            groups[gi].records[ri].speedSamples = s
            
            // Block-epoch speed for display. Start the first block on the first
            // non-zero byte update; thereafter commit a new display value every 2 s
            if groups[gi].records[ri].blockStartTime == nil {
                groups[gi].records[ri].blockStartTime  = now
                groups[gi].records[ri].blockStartBytes = bytes
            } else if let blockStart = groups[gi].records[ri].blockStartTime,
                      now.timeIntervalSince(blockStart) >= 2.0 {
                let elapsed = now.timeIntervalSince(blockStart)
                let delta   = bytes - groups[gi].records[ri].blockStartBytes
                if delta > 0 {
                    groups[gi].records[ri].displaySpeedBytesPerSec = Double(delta) / elapsed
                }
                groups[gi].records[ri].blockStartTime  = now
                groups[gi].records[ri].blockStartBytes = bytes
            }
            
            return
        }
    }
    
    // Cancel handler closures keyed by transfer ID
    private var cancelHandlers: [String: @Sendable () -> Void] = [:]
    
    func registerCancelHandler(id: String, handler: @escaping @Sendable () -> Void) {
        cancelHandlers[id] = handler
    }
    
    /// Fires and discards the cancel handler for `id`. Does not remove the transfer record;
    /// the handler itself is responsible for triggering removal (e.g. via `task.cancel()`
    /// which eventually calls `removeTransfer`, or via `removeTransfer` directly)
    func cancel(id: String) {
        let handler = cancelHandlers.removeValue(forKey: id)
        handler?()
    }
    
    func remove(id: String) {
        cancelHandlers.removeValue(forKey: id)
        for gi in groups.indices {
            if let ri = groups[gi].records.firstIndex(where: { $0.id == id }) {
                let evicted = groups[gi].records.remove(at: ri)
                guard evicted.outcome != nil else { continue }
                if evicted.isUpload {
                    if evicted.outcome == .success { groups[gi].evictedUploadSuccesses += 1 }
                    else { groups[gi].evictedUploadFailures += 1 }
                } else {
                    if evicted.outcome == .success { groups[gi].evictedDownloadSuccesses += 1 }
                    else { groups[gi].evictedDownloadFailures += 1 }
                }
            }
        }
        groups.removeAll { $0.records.isEmpty }
    }
    
    /// Adds `count` to the expected file total for the device group
    /// Called by ShareService when a download batch is first announced or grows
    /// No-op if the group does not exist yet (the call site ensures it does)
    func addExpectedFiles(deviceId: String, count: Int) {
        guard let gi = groups.firstIndex(where: { $0.id == deviceId }) else { return }
        groups[gi].expectedDownloads += count
    }
    
    /// Clamps `expectedDownloads` so it equals the number of downloads that actually arrived
    /// Called when a download batch ends with failures — remaining files will never come,
    /// so the awaiting pill must drop to 0 instead of showing phantom counts
    func clampExpectedFiles(deviceId: String) {
        guard let gi = groups.firstIndex(where: { $0.id == deviceId }) else { return }
        let downloadRecords = groups[gi].records.filter { !$0.isUpload }.count
        let arrived = downloadRecords + groups[gi].evictedDownloadSuccesses + groups[gi].evictedDownloadFailures
        groups[gi].expectedDownloads = min(groups[gi].expectedDownloads, arrived)
    }
    
    /// Marks a transfer as completed, freezes its row in the linger visual state, and
    /// updates its label to the final summary text. Linger duration and row removal are
    /// handled by `TransferProgressHUD` after calling this
    ///
    /// On `.success`, pins `bytesTransferred` to `totalBytes` so the bar always shows 100%
    func complete(id: String, outcome: TransferOutcome, finalLabel: String) {
        for gi in groups.indices {
            guard let ri = groups[gi].records.firstIndex(where: { $0.id == id }) else { continue }
            groups[gi].records[ri].isCompleted = true
            groups[gi].records[ri].outcome = outcome
            groups[gi].records[ri].label = finalLabel
            if outcome == .success, let total = groups[gi].records[ri].totalBytes {
                groups[gi].records[ri].bytesTransferred = total
            }
            return
        }
    }
    
    func toggleExpanded(groupId: String) {
        guard let i = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[i].isExpanded.toggle()
    }
}

// MARK: - TransferProgressHUD Panel

/// Floating, non-activating HUD panel that shows live file transfer progress
///
/// Transfers are **grouped by device**. Each device gets a collapsible section header
/// with a right-aligned info bubble (colored count pills). Individual file rows appear
/// inside the section as packets arrive — reactive, not predictive
///
/// Panel is **fixed at 388 × 168 pt**. A `ScrollView` inside handles any number of groups
/// and rows; the gradient fade at the bottom hints at scrollability
///
/// Usage (safe to call from any thread):
/// ```swift
/// TransferProgressHUD.addTransfer(id:deviceId:deviceName:deviceType:label:totalBytes:isUpload:)
/// TransferProgressHUD.updateProgress(id:bytesTransferred:)
/// TransferProgressHUD.removeTransfer(id:)
/// ```
@MainActor
final class TransferProgressHUD: NSPanel {
    
    static let shared = TransferProgressHUD()
    
    // Height = section header (~36 pt) + one full row (~76 pt) + peek of next / end message (~56 pt).
    private static let panelSize = NSSize(width: 388, height: 168)
    private static let screenMargin: CGFloat = 12
    
    private let store = TransferProgressStore()
    private var dismissTask: Task<Void, Never>?
    /// Per-transfer linger tasks scheduled after `completeTransfer` (keyed by transfer ID)
    private var lingerTasks: [String: Task<Void, Never>] = [:]
    /// Non-nil while a shake animation cooldown is active (prevents rapid-fire stacking)
    private var shakeDebounceTask: Task<Void, Never>?
    
    // MARK: Static API (nonisolated — safe to call from any context)
    
    nonisolated static func addTransfer(id: String, deviceId: String, deviceName: String,
                                        deviceType: DeviceType, label: String,
                                        totalBytes: Int64?, isUpload: Bool) {
        let record = TransferProgressRecord(
            id: id, deviceId: deviceId, deviceName: deviceName, deviceType: deviceType,
            label: label, totalBytes: totalBytes, isUpload: isUpload)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let hud = TransferProgressHUD.shared
                let wasEmpty = hud.store.groups.isEmpty
                hud.store.add(record)
                if wasEmpty {
                    hud.dismissTask?.cancel()
                    hud.store.refreshEndMessage()
                    hud.present()
                }
            }
        }
    }
    
    nonisolated static func updateProgress(id: String, bytesTransferred: Int64) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                TransferProgressHUD.shared.store.update(id: id, bytes: bytesTransferred)
            }
        }
    }
    
    nonisolated static func removeTransfer(id: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let hud = TransferProgressHUD.shared
                hud.lingerTasks.removeValue(forKey: id)?.cancel()
                hud.store.remove(id: id)
                if hud.store.groups.isEmpty { hud.scheduleDismiss() }
            }
        }
    }
    
    /// Marks a transfer as completed, shows its final linger state (green / red icon + frozen bar),
    /// then removes the row after a brief delay and dismisses the panel when all rows are gone
    ///
    /// - Parameters:
    ///   - id: The same ID passed to `addTransfer`
    ///   - outcome: `.success` (green, 3 s linger) · `.failed` / `.cancelled` (red, 8 s linger + shake)
    ///   - finalLabel: Text shown in the row during linger
    nonisolated static func completeTransfer(id: String, outcome: TransferOutcome, finalLabel: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let hud = TransferProgressHUD.shared
                hud.store.complete(id: id, outcome: outcome, finalLabel: finalLabel)
                if outcome != .success { hud.scheduleShake() }
                let duration: TimeInterval = outcome == .success ? 3 : 8
                hud.lingerTasks[id]?.cancel()
                hud.lingerTasks[id] = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(duration))
                    hud.lingerTasks.removeValue(forKey: id)
                    hud.store.remove(id: id)
                    if hud.store.groups.isEmpty { hud.scheduleDismiss() }
                }
            }
        }
    }
    
    /// Informs the HUD that `count` more files are expected from `deviceId` this session
    /// Call once when a download batch is first created, and again (with the delta only)
    /// each time Android grows the batch via `kdeconnect.share.request.update`
    /// Must be called after the first `addTransfer` for the device so the group exists
    nonisolated static func addExpectedFiles(deviceId: String, count: Int) {
        guard count > 0 else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                TransferProgressHUD.shared.store.addExpectedFiles(deviceId: deviceId, count: count)
            }
        }
    }
    
    /// Clamps the expected file count for `deviceId` so the awaiting pill drops to 0
    /// Call when a download batch ends early due to failure — remaining files will never arrive
    nonisolated static func clampExpectedFiles(deviceId: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                TransferProgressHUD.shared.store.clampExpectedFiles(deviceId: deviceId)
            }
        }
    }
    
    /// Registers a closure to be called when the user taps × on the transfer row with `id`
    ///
    /// - For downloads: pass `{ [weak task] in task?.cancel() }`. The cancel triggers
    ///   `downloadTask(_:finishedWithSuccess:false)` which calls `removeTransfer` automatically
    /// - For uploads: mark the packet in `cancelledUploadPacketIds` and call
    ///   `device.cancelUpload(forPacketId:)`. The connection aborts the stream;
    ///   `connection(_:didSendPacket:uploadedPayload:false)` then calls `removeTransfer`
    nonisolated static func registerCancelHandler(id: String, handler: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                TransferProgressHUD.shared.store.registerCancelHandler(id: id, handler: handler)
            }
        }
    }
    
    // MARK: Init
    
    private init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true          // System shadow follows the rounded alpha mask
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient]
        hidesOnDeactivate = false
        isMovable = true
        isMovableByWindowBackground = true
        
        let hosting = RoundedHUDHostingView(rootView: TransferProgressView(store: store))
        contentView = hosting
    }
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    // MARK: Shake
    
    /// Triggers a horizontal shake animation on the panel, debounced to at most once per 1.5 s
    /// This prevents rapid-fire stacking when parallel uploads all fail at once
    private func scheduleShake() {
        guard shakeDebounceTask == nil else { return }
        shakeDebounceTask = Task { @MainActor in
            self.shake()
            try? await Task.sleep(for: .seconds(1.5))
            self.shakeDebounceTask = nil
        }
    }
    
    private func shake() {
        guard let layer = contentView?.layer else { return }
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values   = [0, -8, 8, -6, 6, -4, 4, -2, 2, 0]
        anim.duration = 0.55
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(anim, forKey: "shake")
    }
    
    // MARK: Presentation
    
    private func present() {
        guard let screen = NSScreen.main else { return }
        let size = Self.panelSize
        let m = Self.screenMargin
        // Top-right corner (visibleFrame already excludes the menu bar and Dock)
        setFrame(NSRect(x: screen.visibleFrame.maxX - size.width - m,
                        y: screen.visibleFrame.maxY - size.height - m,
                        width: size.width, height: size.height),
                 display: false)
        
        alphaValue = 0
        orderFrontRegardless()
        
        if let layer = contentView?.layer {
            // Spring scale-in: 0.92 → 1.0 with spring damping for smooth entrance
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: size.width / 2, y: size.height / 2)
            layer.setAffineTransform(CGAffineTransform(scaleX: 0.92, y: 0.92))
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.92; spring.toValue = 1.0
            spring.damping = 14; spring.stiffness = 300; spring.mass = 0.8
            spring.duration = spring.settlingDuration
            spring.isRemovedOnCompletion = false; spring.fillMode = .forwards
            layer.add(spring, forKey: "springScale")
            layer.setAffineTransform(.identity)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }
    
    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            self.fadeOutAndClose()
        }
    }
    
    private func fadeOutAndClose() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { self.close() }
        })
    }
}

// MARK: - Rounded Hosting View

/// NSHostingView subclass that clips content to an 18 pt continuous rounded rect
/// The NSPanel's system shadow follows this alpha mask automatically
private final class RoundedHUDHostingView: NSHostingView<TransferProgressView> {
    private let r: CGFloat = 18
    
    required init(rootView: TransferProgressView) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = r
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    
    override func layout() {
        super.layout()
        layer?.cornerRadius = r
    }
    
    /// Deliver mouse-down events to SwiftUI buttons on the first click, even when
    /// the panel is not the key window. Without this, macOS consumes the first click
    /// as a "window activation" gesture and the button tap is silently dropped
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - SwiftUI Views

struct TransferProgressView: View {
    @ObservedObject var store: TransferProgressStore
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(store.groups) { group in
                        DeviceGroupView(
                            group: group,
                            onToggleExpand: {
                                withAnimation(.spring(duration: 0.3)) {
                                    store.toggleExpanded(groupId: group.id)
                                }
                            },
                            onCancel: { id in store.cancel(id: id) }
                        )
                        // Hairline divider between device groups (not after the last one)
                        if group.id != store.groups.last?.id {
                            Color.primary.opacity(0.07)
                                .frame(height: 0.5)
                                .padding(.horizontal, 16)
                        }
                    }
                    .animation(.spring(duration: 0.28), value: store.groups.map(\.id))
                    
                    // End message shown inline when rows are present
                    if !store.groups.isEmpty {
                        EndMessageView(message: store.endMessage)
                    }
                }
            }
            
            // Empty state: center the end message in the panel frame
            if store.groups.isEmpty {
                VStack {
                    Spacer()
                    EndMessageView(message: store.endMessage)
                    Spacer()
                }
            }
            
            // Bottom gradient hints at scrollability.
            LinearGradient(
                stops: [
                    .init(color: Color.primary.opacity(0), location: 0),
                    .init(color: Color.primary.opacity(0.1), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 28)
            .allowsHitTesting(false)
        }
        .background { glassBackground }
    }
    
    private var glassBackground: some View {
        ZStack {
            HUDVisualEffectView()
            // In dark mode, .popover material can read as too whitish
            // A slight black tint anchors it without killing the translucency
            Color.black.opacity(colorScheme == .dark ? 0.25 : 0)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.8)
        }
    }
}

// MARK: - Device Group Views

/// Collapsible section for one device's transfers: header + per-file rows
///
/// Each row is indented with a `tree`-style rounded connector (├── / └──),
/// with the vertical line aligned to the collapse chevron in the header
private struct DeviceGroupView: View {
    let group: DeviceGroup
    let onToggleExpand: () -> Void
    let onCancel: (String) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            DeviceGroupHeaderView(group: group, onToggleExpand: onToggleExpand)
            
            if group.isExpanded {
                ForEach(group.records) { record in
                    let isLast = group.records.last?.id == record.id
                    HStack(alignment: .top, spacing: 0) {
                        // Aligns connector's vertical line with chevron centre:
                        // 16pt header padding + 12pt (half of 24pt chevron frame) − 2pt (connector x) = 26pt
                        Color.clear.frame(width: 26)
                        RowTreeConnector(isLast: isLast)
                            .frame(width: 20)
                        TransferRowView(record: record, onCancel: { onCancel(record.id) })
                    }
                }
                .animation(.spring(duration: 0.28), value: group.records.map(\.id))
            }
        }
    }
}

/// Section header: collapse chevron (left) + device icon + name + info bubble (right)
///
/// The chevron sits on the **left** to anchor the tree connector lines drawn in child rows
/// It is only shown when the group has 2 or more rows; a same-size placeholder keeps
/// the icon/name aligned in single-row groups
///
/// Tapping the info bubble shows a popover with the full text breakdown
private struct DeviceGroupHeaderView: View {
    let group: DeviceGroup
    let onToggleExpand: () -> Void
    @State private var showingInfoPopover = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Collapse chevron on the LEFT. Uses onTapGesture rather than Button because Button with `.plain` style is unreliable on first tap in nonactivatingPanels
            Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleExpand)
            
            Image(systemName: group.deviceType.sfSymbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            
            Text(group.deviceName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            Spacer()
            
            // Info bubble: tap for full-text breakdown (uses onTapGesture, same reason as chevron)
            InfoBubbleView(group: group)
                .contentShape(Rectangle())
                .onTapGesture { showingInfoPopover = true }
                .popover(isPresented: $showingInfoPopover, arrowEdge: .bottom) {
                    Text(infoSummaryText)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minWidth: 180, maxWidth: 300)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }
    
    private var infoSummaryText: String {
        let records = group.records
        func n(_ c: Int, _ sing: String, _ plur: String) -> String { c == 1 ? sing : plur }
        
        let uploading   = records.filter {  $0.isUpload && !$0.isCompleted && $0.bytesTransferred > 0 }.count
        let downloading = records.filter { !$0.isUpload && !$0.isCompleted && $0.bytesTransferred > 0 }.count
        let awaitSend   = records.filter {  $0.isUpload && !$0.isCompleted && $0.bytesTransferred == 0 }.count
        let awaitRecvRows     = records.filter { !$0.isUpload && !$0.isCompleted && $0.bytesTransferred == 0 }.count
        let downloadsArrived  = records.filter { !$0.isUpload }.count + group.evictedDownloadSuccesses + group.evictedDownloadFailures
        let awaitRecvExpected = max(0, group.expectedDownloads - downloadsArrived)
        let awaitRecv         = awaitRecvRows + awaitRecvExpected
        
        // Session totals = evicted + still-lingering rows, kept separate by direction.
        let lingerSent        = records.filter { $0.isCompleted &&  $0.isUpload && $0.outcome == .success }.count
        let lingerReceived    = records.filter { $0.isCompleted && !$0.isUpload && $0.outcome == .success }.count
        let lingerFailedSend  = records.filter { $0.isCompleted &&  $0.isUpload && $0.outcome != .success && $0.outcome != nil }.count
        let lingerFailedRecv  = records.filter { $0.isCompleted && !$0.isUpload && $0.outcome != .success && $0.outcome != nil }.count
        let totalSent        = group.evictedUploadSuccesses   + lingerSent
        let totalReceived    = group.evictedDownloadSuccesses + lingerReceived
        let totalFailedSend  = group.evictedUploadFailures    + lingerFailedSend
        let totalFailedRecv  = group.evictedDownloadFailures  + lingerFailedRecv
        
        var parts: [String] = []
        if uploading       > 0 { parts.append("Sending \(uploading) \(n(uploading, "file", "files"))") }
        if downloading     > 0 { parts.append("Receiving \(downloading) \(n(downloading, "file", "files"))") }
        if awaitSend       > 0 { parts.append("Awaiting to send \(awaitSend) \(n(awaitSend, "file", "files"))") }
        if awaitRecv       > 0 { parts.append("Awaiting to receive \(awaitRecv) \(n(awaitRecv, "file", "files"))") }
        if totalSent       > 0 { parts.append("Sent \(totalSent) \(n(totalSent, "file", "files"))") }
        if totalReceived   > 0 { parts.append("Received \(totalReceived) \(n(totalReceived, "file", "files"))") }
        if totalFailedSend > 0 { parts.append("Failed to send \(totalFailedSend) \(n(totalFailedSend, "file", "files"))") }
        if totalFailedRecv > 0 { parts.append("Failed to receive \(totalFailedRecv) \(n(totalFailedRecv, "file", "files"))") }
        return parts.isEmpty ? "No active transfers" : parts.joined(separator: " · ")
    }
}

/// Right-aligned colored count pills showing the state breakdown for a device's transfers
///
/// Only non-zero categories are rendered:
/// - `↑ N` purple  — uploading (active: `bytesTransferred > 0`)
/// - `↓ N` blue    — downloading (active: `bytesTransferred > 0`)
/// - `⏳ N` amber  — awaiting (`bytesTransferred == 0`, any direction)
/// - `✓ N` green   — succeeded
/// - `✗ N` red     — failed / cancelled
///
/// Awaiting is purely reactive — when `bytesTransferred` changes in the store, SwiftUI
/// re-renders this view automatically. No `TimelineView` or timer needed
private struct InfoBubbleView: View {
    let group: DeviceGroup
    
    private var records: [TransferProgressRecord] { group.records }
    
    // Active counts — live records only.
    private var uploading:   Int { records.filter {  $0.isUpload && !$0.isCompleted && $0.bytesTransferred > 0 }.count }
    private var downloading: Int { records.filter { !$0.isUpload && !$0.isCompleted && $0.bytesTransferred > 0 }.count }
    
    // Awaiting = rows with no bytes yet + downloads expected but not yet arrived
    private var awaitingInRows: Int { records.filter { !$0.isCompleted && $0.bytesTransferred == 0 }.count }
    private var downloadsArrived: Int {
        records.filter { !$0.isUpload }.count + group.evictedDownloadSuccesses + group.evictedDownloadFailures
    }
    private var awaitingExpected: Int { max(0, group.expectedDownloads - downloadsArrived) }
    private var awaiting: Int { awaitingInRows + awaitingExpected }
    
    // Persistent success/fail = evicted (by direction) + still-lingering rows
    private var succeeded: Int {
        group.evictedUploadSuccesses + group.evictedDownloadSuccesses + records.filter { $0.isCompleted && $0.outcome == .success }.count
    }
    private var failed: Int {
        group.evictedUploadFailures + group.evictedDownloadFailures + records.filter { $0.isCompleted && $0.outcome != .success && $0.outcome != nil }.count
    }
    
    var body: some View {
        HStack(spacing: 6) {
            pill("arrow.up",   count: uploading,   color: .purple)
            pill("arrow.down", count: downloading, color: .blue)
            pill("hourglass",  count: awaiting,    color: .amber)
            pill("checkmark",  count: succeeded,   color: .hudSuccess)
            pill("xmark",      count: failed,      color: .hudFailure)
        }
    }
    
    @ViewBuilder
    private func pill(_ symbol: String, count: Int, color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(color)
        }
    }
}

// MARK: - Tree Connector

/// `tree`-style rounded connector drawn to the left of each transfer row
///
/// Draws `├──` for non-last rows and `└──` for the last row, with the corner
/// rounded via a quadratic Bézier curve — matching the visual style of
/// Finder's list-view disclosure groups.
private struct RowTreeConnector: View {
    let isLast: Bool
    
    var body: some View {
        Canvas { context, size in
            let x: CGFloat = 2
            let r: CGFloat = 4.5
            let mid = size.height / 2
            // Draw at full opacity; .opacity(0.22) is applied at the view level.
            // Prevents overlapping paths from compounding alpha at junctions
            let color = GraphicsContext.Shading.color(Color.primary)
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            
            if isLast {
                // └── : single continuous path — no junction endpoint, no cap overlap
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: mid - r))
                path.addQuadCurve(
                    to: CGPoint(x: x + 2 * r, y: mid),
                    control: CGPoint(x: x, y: mid)
                )
                path.addLine(to: CGPoint(x: size.width, y: mid))
                context.stroke(path, with: color, style: style)
            } else {
                // ├── : stem + branch as separate paths. Both at opacity 1.0 so their
                // overlap at the T-junction composites to 1.0 (not double-alpha)
                var stem = Path()
                stem.move(to: CGPoint(x: x, y: 0))
                stem.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(stem, with: color, style: style)
                
                var branch = Path()
                branch.move(to: CGPoint(x: x, y: mid - r))
                branch.addQuadCurve(
                    to: CGPoint(x: x + 2 * r, y: mid),
                    control: CGPoint(x: x, y: mid)
                )
                branch.addLine(to: CGPoint(x: size.width, y: mid))
                context.stroke(branch, with: color, style: style)
            }
        }
        .opacity(0.22)
    }
}

// MARK: - Transfer Row

/// One file transfer row. Device name is in the section header above — omitted here
///
/// Awaiting state: row starts with `bytesTransferred == 0`, shows amber icon and indeterminate bar.
/// When the first byte arrives, the store triggers a re-render and the row shows real color,
/// progress bar, and percentage. Reactivity is purely store-driven, no timers needed
struct TransferRowView: View {
    let record: TransferProgressRecord
    let onCancel: () -> Void
    @State private var isHoveringLabel = false
    
    /// True while no data has arrived yet (and the row is not in a terminal linger state)
    private var isAwaiting: Bool { !record.isCompleted && record.bytesTransferred == 0 }
    
    /// Semantic color for the current row state
    ///
    /// | State      | Color  |
    /// |------------|--------|
    /// | Awaiting   | amber  |
    /// | Upload     | purple |
    /// | Download   | blue   |
    /// | Success    | green  |
    /// | Failure    | red    |
    private var stateColor: Color {
        if isAwaiting { return .amber }
        switch record.outcome {
        case .success:             return .hudSuccess
        case .failed, .cancelled:  return .hudFailure
        case .none:                return record.isUpload ? .purple : .blue
        }
    }
    
    /// "Awaiting [filename]" — shown while no bytes have arrived yet
    private var awaitingLabel: String { "Awaiting \(record.label)" }
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            
            // Icon card:
            //   awaiting  → amber
            //   active    → direction color (purple/blue)
            //   linger    → outcome color (green/red)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                Image(systemName: record.deviceType.sfSymbolName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(stateColor)
            }
            .frame(width: 48, height: 48)
            
            VStack(alignment: .leading, spacing: 6) {
                
                // Row 1: big % | label | speed
                // Fixed minHeight so awaiting (no %) and active (26pt %) share the same row height
                HStack(alignment: .bottom, spacing: 8) {
                    // % — only shown when actively transferring
                    if let fraction = record.fractionCompleted, !isAwaiting {
                        Text("\(Int(fraction * 100))%")
                            .font(.system(size: 26, weight: .bold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .fixedSize()
                    }
                    
                    // Label: "Awaiting <filename>" / "<filename>"
                    Text(isAwaiting ? awaitingLabel : record.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onHover { isHoveringLabel = $0 }
                    
                    // Speed — hidden when awaiting or linger-complete.
                    // Fixed 76 pt slot so the arrow and filename never shift as the
                    // value changes. displaySpeedBytesPerSec updates only once per
                    // 2-second block, keeping the number visually stable.
                    if !isAwaiting && !record.isCompleted, let speed = record.displaySpeedBytesPerSec {
                        HStack(spacing: 3) {
                            Image(systemName: record.isUpload ? "arrow.up" : "arrow.down")
                                .font(.system(size: 9, weight: .bold))
                            Text(formatSpeed(speed))
                                .font(.system(size: 11).monospacedDigit())
                        }
                        .foregroundStyle(stateColor)
                        .frame(minWidth: 67, alignment: .trailing)
                    }
                }
                .frame(minHeight: 31, alignment: .bottom)  // 26pt font ≈ 31pt line height
                
                // Row 2: indeterminate when awaiting; always direction-colored (purple/blue)
                HUDProgressBar(
                    fraction: isAwaiting ? nil : record.fractionCompleted,
                    color: record.isUpload ? .purple : .blue
                )
                
                // Row 3: ETA — hidden when awaiting or linger-complete; always rendered for stable height
                Text((!isAwaiting && !record.isCompleted ? record.etaSeconds : nil).map { formatETA($0) } ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .opacity(!isAwaiting && !record.isCompleted && record.etaSeconds != nil ? 1 : 0)
            }
            .overlay(alignment: .topLeading) {
                if isHoveringLabel {
                    Text(record.label)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .offset(y: 35)
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeInOut(duration: 0.12)))
                }
            }
            
            // Cancel button — disappears during linger
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(record.isCompleted ? 0 : 1)
        }
        .zIndex(isHoveringLabel ? 1 : 0)
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
    }
    
    private func formatSpeed(_ bps: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
    }
    
    private func formatETA(_ s: Double) -> String {
        s < 60 ? "\(Int(s))s remaining" : "\(Int(s) / 60)m \(Int(s) % 60)s remaining"
    }
}

// MARK: - End Message

/// Always-visible footer at the bottom of the scroll view
private struct EndMessageView: View {
    let message: String
    
    var body: some View {
        Text(message)
            .font(.system(size: 13).italic())
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 10)
            .frame(height: 40, alignment: .top)
    }
}

// MARK: - Visual Effect Background

/// NSVisualEffectView wrapped for SwiftUI. Inherits appearance from the NSPanel
private struct HUDVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover   // adapts naturally to light and dark appearance
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Custom Progress Bar

/// Colored progress bar for both determinate and indeterminate states
///
/// `.tint()` on SwiftUI's `ProgressView` is backed by `NSProgressIndicator` which ignores
/// custom tint colors at runtime — Xcode Preview fakes it correctly, don't be fooled
/// Both branches use custom Capsule draws so color is reliable in light and dark mode
///
/// - Determinate (`fraction != nil`): fill expands with a spring animation
/// - Indeterminate (`fraction == nil`): a fixed-width segment slides back and forth,
///   clipped to the track bounds. In the centre the full segment is visible; at the edges
///   it tucks behind the track like a bar sliding behind a wall, leaving only a bold-dot
///   minimum visible — identical to the native macOS indeterminate `ProgressView` shape
///   `.easeInOut` + `autoreverses` gives the decelerate → pause → accelerate cadence
///   Rendered at 0.65 opacity to read as "pending" vs "actively transferring"
private struct HUDProgressBar: View {
    let fraction: Double?
    let color: Color
    @State private var phase: CGFloat = 0
    /// Animated display fraction. Starts at 0 so the first determinate value
    /// springs in from empty rather than jumping to e.g. 72% instantly
    @State private var displayFraction: CGFloat = 0
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if let f = fraction {
                    Capsule()
                        .fill(color)
                        .frame(width: max(w * displayFraction, 6))
                        .animation(.spring(duration: 0.4), value: displayFraction)
                        .onChange(of: f) { _, newVal in
                            displayFraction = CGFloat(newVal)
                        }
                        .onAppear {
                            // Animate from 0 → current fraction on first render
                            withAnimation(.spring(duration: 0.5)) {
                                displayFraction = CGFloat(f)
                            }
                        }
                } else {
                    let segWidth: CGFloat = w * 0.35
                    let minVisible: CGFloat = 6
                    // Leading edge: from -(segWidth - minVisible) to (w - minVisible)
                    let startX = -(segWidth - minVisible)
                    let endX   = w - minVisible
                    
                    Capsule()
                        .fill(color)
                        .frame(width: segWidth)
                        .offset(x: startX + phase * (endX - startX))
                        .opacity(0.35)
                        // Scope the repeatForever animation to this capsule only
                        // Using withAnimation in the outer onAppear propagates the transaction
                        // up through NSVisualEffectView, causing material tinting to pulse in
                        // sync with the bounce (veil flicker, vibrancy text-color switching)
                        .animation(
                            .easeInOut(duration: 1.3).repeatForever(autoreverses: true),
                            value: phase
                        )
                        .onAppear { phase = 1 }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}

// MARK: - Color Extensions

private extension Color {
    /// Amber — used for the awaiting state (bytesTransferred == 0).
    static let amber      = Color(red: 1.00, green: 0.70, blue: 0.00)
    /// Muted green — success linger (icon + info bubble pill).
    static let hudSuccess = Color(red: 0.34, green: 0.67, blue: 0.46)
    /// Muted red — failure / cancelled linger (icon + info bubble pill).
    static let hudFailure = Color(red: 0.76, green: 0.38, blue: 0.38)
}


// MARK: - Previews

#Preview("Single file — one device") {
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        var r = TransferProgressRecord(id: "1", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                       deviceType: .Phone, label: "vacation.mp4",
                                       totalBytes: 45_000_000, isUpload: true)
        r.bytesTransferred = 32_500_000
        r.speedSamples = [SpeedSample(bytes: 24_000_000, time: Date(timeIntervalSinceNow: -4)),
                          SpeedSample(bytes: 32_500_000, time: Date())]
        r.displaySpeedBytesPerSec = 2_125_000  // (32.5 MB − 24 MB) / 4 s
        s.add(r)
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Two files — same device, collapsed") {
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        var r1 = TransferProgressRecord(id: "1", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "vacation.mp4",
                                        totalBytes: 45_000_000, isUpload: true)
        r1.bytesTransferred = 32_500_000
        r1.speedSamples = [SpeedSample(bytes: 24_000_000, time: Date(timeIntervalSinceNow: -4)),
                           SpeedSample(bytes: 32_500_000, time: Date())]
        r1.displaySpeedBytesPerSec = 2_125_000  // (32.5 MB − 24 MB) / 4 s
        var r2 = TransferProgressRecord(id: "2", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "document.pdf",
                                        totalBytes: 8_200_000, isUpload: true)
        r2.bytesTransferred = 1_200_000
        r2.speedSamples = [SpeedSample(bytes: 600_000, time: Date(timeIntervalSinceNow: -3)),
                           SpeedSample(bytes: 1_200_000, time: Date())]
        r2.displaySpeedBytesPerSec = 200_000    // (1.2 MB − 0.6 MB) / 3 s
        s.add(r1); s.add(r2)
        s.groups[0].isExpanded = false
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Two devices — simultaneous transfers") {
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        var r1 = TransferProgressRecord(id: "1", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "vacation.mp4",
                                        totalBytes: 45_000_000, isUpload: true)
        r1.bytesTransferred = 32_500_000
        r1.speedSamples = [SpeedSample(bytes: 24_000_000, time: Date(timeIntervalSinceNow: -4)),
                           SpeedSample(bytes: 32_500_000, time: Date())]
        r1.displaySpeedBytesPerSec = 2_125_000  // (32.5 MB − 24 MB) / 4 s
        var r2 = TransferProgressRecord(id: "2", deviceId: "dev2", deviceName: "Surface Pro",
                                        deviceType: .Laptop, label: "quarterly-report.pdf",
                                        totalBytes: 8_200_000, isUpload: false)
        r2.bytesTransferred = 1_200_000
        r2.speedSamples = [SpeedSample(bytes: 600_000, time: Date(timeIntervalSinceNow: -3)),
                           SpeedSample(bytes: 1_200_000, time: Date())]
        r2.displaySpeedBytesPerSec = 200_000    // (1.2 MB − 0.6 MB) / 3 s
        s.add(r1); s.add(r2)
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Linger states — success · failure · cancelled") {
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        
        // Success linger (green)
        var r1 = TransferProgressRecord(id: "ok", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "vacation.mp4",
                                        totalBytes: 45_000_000, isUpload: false)
        r1.bytesTransferred = 45_000_000
        r1.isCompleted = true; r1.outcome = .success
        s.add(r1)
        
        // Failure linger (red)
        var r2 = TransferProgressRecord(id: "fail", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "report.pdf",
                                        totalBytes: 8_000_000, isUpload: false)
        r2.bytesTransferred = 3_200_000
        r2.isCompleted = true; r2.outcome = .failed
        s.add(r2)
        
        // Cancelled linger (red)
        var r3 = TransferProgressRecord(id: "cxl", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "Cancelled",
                                        totalBytes: 12_000_000, isUpload: true)
        r3.bytesTransferred = 1_500_000
        r3.isCompleted = true; r3.outcome = .cancelled
        s.add(r3)
        
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Awaiting → Active (auto-transitions after 3 s)") {
    struct Demo: View {
        @StateObject private var store: TransferProgressStore = {
            let s = TransferProgressStore()
            // bytesTransferred defaults to 0 → isAwaiting = true on first render
            s.add(TransferProgressRecord(
                id: "1", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                deviceType: .Phone, label: "vacation.mp4",
                totalBytes: 45_000_000, isUpload: false
            ))
            return s
        }()
        
        var body: some View {
            TransferProgressView(store: store)
                .task {
                    // 3 s in: first bytes arrive → amber → blue, real bar
                    try? await Task.sleep(for: .seconds(3))
                    store.update(id: "1", bytes: 8_000_000)
                    // 2 s later: more progress
                    try? await Task.sleep(for: .seconds(2))
                    store.update(id: "1", bytes: 32_500_000)
                }
        }
    }
    return Demo()
        .frame(width: 388, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Indeterminate — batch upload") {
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        var r = TransferProgressRecord(id: "1", deviceId: "dev1", deviceName: "Galaxy Tab S9",
                                       deviceType: .Tablet, label: "vacation.mp4",
                                       totalBytes: nil, isUpload: true)
        r.bytesTransferred = 4_200_000
        s.add(r)
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Awaiting — batch queued, not started") {
    // All rows have bytesTransferred == 0 → isAwaiting: amber icon, indeterminate bar
    // Info bubble shows ⏳ 3
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        for (id, name, bytes) in [("1", "vacation.mp4", Int64(45_000_000)),
                                  ("2", "birthday.heic", Int64(12_300_000)),
                                  ("3", "audio.m4a",     Int64(3_100_000))] {
            s.add(TransferProgressRecord(id: id, deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                         deviceType: .Phone, label: name,
                                         totalBytes: bytes, isUpload: true))
        }
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Mixed — awaiting + active upload") {
    // Row 1: active (purple bar). Row 2: awaiting (amber, indeterminate)
    // Info bubble shows ↑ 1, ⏳ 1
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        var r1 = TransferProgressRecord(id: "1", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "vacation.mp4",
                                        totalBytes: 45_000_000, isUpload: true)
        r1.bytesTransferred = 22_500_000
        r1.speedSamples = [SpeedSample(bytes: 10_000_000, time: Date(timeIntervalSinceNow: -5)),
                           SpeedSample(bytes: 22_500_000, time: Date())]
        r1.displaySpeedBytesPerSec = 2_500_000  // (22.5 MB − 10 MB) / 5 s
        s.add(r1)
        s.add(TransferProgressRecord(id: "2", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                     deviceType: .Phone, label: "birthday.heic",
                                     totalBytes: 12_300_000, isUpload: true))
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Download in progress — single file") {
    // Blue icon and progress bar (isUpload: false)
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        var r = TransferProgressRecord(id: "1", deviceId: "dev1", deviceName: "Galaxy Tab S9",
                                       deviceType: .Tablet, label: "quarterly-report.pdf",
                                       totalBytes: 32_000_000, isUpload: false)
        r.bytesTransferred = 18_400_000
        r.speedSamples = [SpeedSample(bytes: 8_000_000, time: Date(timeIntervalSinceNow: -6)),
                          SpeedSample(bytes: 18_400_000, time: Date())]
        r.displaySpeedBytesPerSec = 1_733_333  // (18.4 MB − 8 MB) / 6 s
        s.add(r)
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Download — expected files ahead of arrival") {
    // Android announced 5 files; only 1 packet has arrived so far
    // Info bubble: ↓ 1 (blue, active) + ⏳ 4 (amber, expected-but-not-arrived)
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        var r = TransferProgressRecord(id: "1", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                       deviceType: .Phone, label: "vacation.mp4",
                                       totalBytes: 45_000_000, isUpload: false)
        r.bytesTransferred = 12_000_000
        r.speedSamples = [SpeedSample(bytes: 4_000_000, time: Date(timeIntervalSinceNow: -5)),
                          SpeedSample(bytes: 12_000_000, time: Date())]
        r.displaySpeedBytesPerSec = 1_600_000  // (12 MB − 4 MB) / 5 s
        s.add(r)
        s.addExpectedFiles(deviceId: "dev1", count: 5)
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Mixed directions — upload + download, same device") {
    // One upload (purple) and one download (blue) from the same device simultaneously
    // Info bubble: ↑ 1, ↓ 1
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        var up = TransferProgressRecord(id: "up1", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "presentation.key",
                                        totalBytes: 28_000_000, isUpload: true)
        up.bytesTransferred = 16_800_000
        up.speedSamples = [SpeedSample(bytes: 6_000_000, time: Date(timeIntervalSinceNow: -5)),
                           SpeedSample(bytes: 16_800_000, time: Date())]
        up.displaySpeedBytesPerSec = 2_160_000  // (16.8 MB − 6 MB) / 5 s
        var dn = TransferProgressRecord(id: "dn1", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "vacation.mp4",
                                        totalBytes: 45_000_000, isUpload: false)
        dn.bytesTransferred = 27_000_000
        dn.speedSamples = [SpeedSample(bytes: 10_000_000, time: Date(timeIntervalSinceNow: -6)),
                           SpeedSample(bytes: 27_000_000, time: Date())]
        dn.displaySpeedBytesPerSec = 2_833_333  // (27 MB − 10 MB) / 6 s
        s.add(up); s.add(dn)
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Partial success") {
    // 2 success lingers + 1 failure linger
    // Info bubble: ✓ 2 (green), ✗ 1 (red)
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        var ok1 = TransferProgressRecord(id: "ok1", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                         deviceType: .Phone, label: "vacation.mp4",
                                         totalBytes: 45_000_000, isUpload: true)
        ok1.bytesTransferred = 45_000_000
        ok1.isCompleted = true; ok1.outcome = .success
        var ok2 = TransferProgressRecord(id: "ok2", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                         deviceType: .Phone, label: "birthday.heic",
                                         totalBytes: 12_000_000, isUpload: true)
        ok2.bytesTransferred = 12_000_000
        ok2.isCompleted = true; ok2.outcome = .success
        var fail = TransferProgressRecord(id: "f1", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                          deviceType: .Phone, label: "report.pdf",
                                          totalBytes: 8_200_000, isUpload: true)
        fail.bytesTransferred = 3_100_000
        fail.isCompleted = true; fail.outcome = .failed
        s.add(ok1); s.add(ok2); s.add(fail)
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Total failure — all files failed") {
    // No successes → all rows red. Info bubble: ✗ 2
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        var f1 = TransferProgressRecord(id: "f1", deviceId: "dev1", deviceName: "Surface Pro",
                                        deviceType: .Laptop, label: "backup.zip",
                                        totalBytes: 500_000_000, isUpload: true)
        f1.bytesTransferred = 40_000_000
        f1.isCompleted = true; f1.outcome = .failed
        var f2 = TransferProgressRecord(id: "f2", deviceId: "dev1", deviceName: "Surface Pro",
                                        deviceType: .Laptop, label: "archive.tar",
                                        totalBytes: 200_000_000, isUpload: true)
        f2.isCompleted = true; f2.outcome = .failed
        s.add(f1); s.add(f2)
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("All succeeded — evicted, ✓ pill from counters") {
    // All rows have already been evicted after linger. The group stays alive
    // because expectedDownloads > arrived (2 more files still expected)
    // Info bubble: ✓ 5 (green), ⏳ 2 (amber). No rows under the header
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        // Seed the group, then patch counters directly and clear records
        s.add(TransferProgressRecord(id: "_seed", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                     deviceType: .Phone, label: "",
                                     totalBytes: nil, isUpload: true))
        s.groups[0].evictedUploadSuccesses   = 3
        s.groups[0].evictedDownloadSuccesses = 2
        s.groups[0].expectedDownloads        = 4  // 2 arrived (evicted) + 2 still expected
        s.groups[0].records.removeAll()
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Info bubble — all 5 pills active") {
    // One device with uploading + downloading + awaiting + success linger + failure linger
    // Info bubble: ↑ 1, ↓ 1, ⏳ 1, ✓ 1, ✗ 1
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        var up = TransferProgressRecord(id: "up", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "vacation.mp4",
                                        totalBytes: 45_000_000, isUpload: true)
        up.bytesTransferred = 20_000_000
        up.speedSamples = [SpeedSample(bytes: 8_000_000, time: Date(timeIntervalSinceNow: -5)),
                           SpeedSample(bytes: 20_000_000, time: Date())]
        up.displaySpeedBytesPerSec = 2_400_000  // (20 MB − 8 MB) / 5 s
        var dn = TransferProgressRecord(id: "dn", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "report.pdf",
                                        totalBytes: 32_000_000, isUpload: false)
        dn.bytesTransferred = 15_000_000
        dn.speedSamples = [SpeedSample(bytes: 5_000_000, time: Date(timeIntervalSinceNow: -4)),
                           SpeedSample(bytes: 15_000_000, time: Date())]
        dn.displaySpeedBytesPerSec = 2_500_000  // (15 MB − 5 MB) / 4 s
        let aw = TransferProgressRecord(id: "aw", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "birthday.heic",
                                        totalBytes: 12_000_000, isUpload: true)
        var ok = TransferProgressRecord(id: "ok", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "notes.txt",
                                        totalBytes: 1_200_000, isUpload: true)
        ok.bytesTransferred = 1_200_000
        ok.isCompleted = true; ok.outcome = .success
        var fl = TransferProgressRecord(id: "fl", deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                        deviceType: .Phone, label: "archive.zip",
                                        totalBytes: 200_000_000, isUpload: false)
        fl.bytesTransferred = 50_000_000
        fl.isCompleted = true; fl.outcome = .failed
        s.add(up); s.add(dn); s.add(aw); s.add(ok); s.add(fl)
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 530)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("All device types — one group each") {
    // Phone, Tablet, Laptop, Desktop, TV, Unknown — each with one active transfer
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        let devices: [(String, String, DeviceType, String, Int64, Int64, Bool)] = [
            ("ph", "Pixel 9 Pro",   .Phone,     "vacation.mp4",         45_000_000,     32_500_000,     true),
            ("tb", "Galaxy Tab S9", .Tablet,    "quarterly-report.pdf", 8_200_000,      1_200_000,      false),
            ("lp", "Surface Pro",   .Laptop,    "backup.zip",           120_000_000,    60_000_000,     true),
            ("dt", "Mac Studio",    .Desktop,   "project.tar",          500_000_000,    220_000_000,    false),
            ("tv", "Apple TV",      .TV,        "movie.mov",            340_000_000,    180_000_000,    true),
            ("un", "Potato PC",     .Unknown,   "potato.xz",            5_000_000,      2_000_000,      false),
        ]
        for (devId, devName, devType, label, total, sent, isUp) in devices {
            var r = TransferProgressRecord(id: devId, deviceId: devId, deviceName: devName,
                                           deviceType: devType, label: label,
                                           totalBytes: total, isUpload: isUp)
            r.bytesTransferred = sent
            r.speedSamples = [SpeedSample(bytes: sent / 2, time: Date(timeIntervalSinceNow: -5)),
                              SpeedSample(bytes: sent,     time: Date())]
            r.displaySpeedBytesPerSec = Double(sent) / 10.0  // (sent − sent/2) / 5 s
            s.add(r)
        }
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Many files") {
    // 6 rows under one device
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        let files: [(String, String, Int64, Int64)] = [
            ("1", "vacation-day-1.mp4",    45_000_000, 45_000_000),
            ("2", "vacation-day-2.mp4",    52_000_000, 31_000_000),
            ("3", "vacation-day-3.mp4",    38_000_000, 12_000_000),
            ("4", "birthday-party.heic",   12_300_000,          0),
            ("5", "family-portrait.heic",   8_700_000,          0),
            ("6", "audio-memo.m4a",         3_100_000,          0),
        ]
        for (id, name, total, sent) in files {
            var r = TransferProgressRecord(id: id, deviceId: "dev1", deviceName: "Pixel 9 Pro",
                                           deviceType: .Phone, label: name,
                                           totalBytes: total, isUpload: true)
            r.bytesTransferred = sent
            if sent > 0 {
                r.speedSamples = [SpeedSample(bytes: sent / 2, time: Date(timeIntervalSinceNow: -5)),
                                  SpeedSample(bytes: sent,     time: Date())]
                r.displaySpeedBytesPerSec = Double(sent) / 10.0  // (sent − sent/2) / 5 s
            }
            s.add(r)
        }
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 600)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Long names — truncation stress") {
    // Very long device name and filename — verifies ellipsisation, not layout break
    let store: TransferProgressStore = {
        let s = TransferProgressStore()
        var r = TransferProgressRecord(
            id: "1",
            deviceId: "dev1",
            deviceName: "Samsung Galaxy S24 Ultra 5G (Work/Company Phone)",
            deviceType: .Phone,
            label: "very-long-filename-that-should-ellipsize-gracefully-when-it-overflows-the-row.mp4",
            totalBytes: 2_200_000_000,
            isUpload: false
        )
        r.bytesTransferred = 430_000_000
        r.speedSamples = [SpeedSample(bytes: 98_000_000, time: Date(timeIntervalSinceNow: -10)),
                          SpeedSample(bytes: 10_090_000_000, time: Date())]
        r.displaySpeedBytesPerSec = 999_200_000  // (10090 MB − 98 MB) / 10 s
        s.add(r)
        return s
    }()
    TransferProgressView(store: store)
        .frame(width: 388, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

#Preview("Empty store — end message only") {
    TransferProgressView(store: TransferProgressStore())
        .frame(width: 388, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
}
