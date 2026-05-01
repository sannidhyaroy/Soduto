//
//  WebcamService.swift
//  Soduto
//
//  Created by Sannidhya Roy on 14/04/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import VideoToolbox
import AVFoundation
import SwiftUI
import os

// MARK: - WebcamService

/// Streams the paired Android device's camera to macOS.
///
/// Protocol flow (KDE Connect channel):
///   macOS → Android: `kdeconnect.webcam.request_stream`  { addresses, port, width, height, fps, codec }
///   Android → macOS: `kdeconnect.webcam.stream_status`   { streaming, codec, rotation, cameras, activeCamera, zoomRange, opticalZooms, activeZoom, flashAvailable, flashActive, error }
///   macOS ↔ Android: `kdeconnect.webcam.camera_control`  { camera?, zoom?, flash? }
///
/// Media is delivered out-of-band over UDP (not through the KDE Connect TLS channel).
/// Each UDP datagram carries an 18-byte header followed by up to 1400 bytes of payload
/// (H.264/H.265 NAL unit fragment, AAC audio frame fragment).
/// Header: sequenceNumber(4) + ptsMs(4) + frameTotalSize(4) + fragmentOffset(4) + flags(1) + streamType(1)
/// streamType: 0=primary video, 2=audio.
///
/// Decoded frames are displayed in a floating NSWindow using AVSampleBufferDisplayLayer;
/// audio plays through AVAudioEngine.
public class WebcamService: IncomingService {
    
    // MARK: Types
    
    enum ActionId: ServiceAction.Id {
        case startWebcam
        case stopWebcam
    }
    
    enum StreamCodec: String {
        case h265, h264
    }
    
    enum StreamState {
        case idle
        case requestSent(device: Device, port: UInt16)
        case streaming(device: Device, codec: StreamCodec)
    }
    
    // MARK: IncomingService conformance
    
    public static let serviceId: Service.Id = "com.soduto.services.webcam"
    
    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.Webcam.incomingKey
    
    /// We receive stream_status; only advertised when the service is enabled.
    public var incomingCapabilities: Set<Service.Capability> {
        incomingEnabled ? [DataPacket.webcamStreamStatusPacketType] : []
    }
    
    /// Always advertise request_stream and camera_control so Android enables the WebcamPlugin.
    public let outgoingCapabilities: Set<Service.Capability> = [
        DataPacket.webcamRequestStreamPacketType,
        DataPacket.webcamCameraControlPacketType
    ]
    
    // MARK: Stream state
    
    private var streamState: StreamState = .idle
    
    /// Incremented every time a new stream is started. Captured in each window's
    /// `onClose` closure so that a deferred close of a *previous* window's
    /// controller cannot tear down a newly-started stream.
    private var streamGeneration: Int = 0
    
    // MARK: Camera
    
    /// Camera currently in use (sent in request_stream and switch_camera packets).
    private var streamCamera: String = "back"
    /// Cameras advertised by Android in the last stream_status packet.
    private var availableCameras: [WebcamCamera] = []
    
    // MARK: UDP  (POSIX socket — NWListener+UDP hits NECP EEXIST in the sandbox)
    
    private var udpSocket: Int32 = -1
    private var udpSource: DispatchSourceRead?
    
    // MARK: Frame reassembly
    
    private var videoReassembly: [UInt32: ReassemblyBuffer] = [:]
    private var audioReassembly: [UInt32: ReassemblyBuffer] = [:]
    private var currentVideoFrameKey: UInt32? = nil
    private var currentAudioFrameKey: UInt32? = nil
    
    // MARK: Video decoding
    
    private var decompressionSession: VTDecompressionSession?
    private var videoFormatDescription: CMFormatDescription?
    
    // MARK: Audio decoding
    
    private var audioConverter: AVAudioConverter?
    private var pcmFormat: AVAudioFormat?
    
    // MARK: Preview window
    
    private var previewWindowController: WebcamPreviewWindowController?
    
    
    // MARK: Service protocol
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        Logger.services.debug("WebcamService.handleDataPacket: type=\(dataPacket.type, privacy: .public)")
        guard dataPacket.type == DataPacket.webcamStreamStatusPacketType else { return false }
        guard incomingEnabled else { return true }
        
        let streaming = dataPacket.body["streaming"] as? Bool ?? false
        
        if streaming {
            let codec = (dataPacket.body["codec"] as? String).flatMap(StreamCodec.init(rawValue:)) ?? .h265
            let rotation = dataPacket.body["rotation"] as? Int ?? 0
            let cameras  = (dataPacket.body["cameras"] as? [String] ?? []).map(WebcamCamera.init(id:))
            let flashAvailable = dataPacket.body["flashAvailable"] as? Bool ?? false
            let flashActive = dataPacket.body["flashActive"] as? Bool ?? false
            
            // Extract zoom range and optical zoom points
            var zoomMin: Float = 1.0
            var zoomMax: Float = 1.0
            if let zoomRangeArray = dataPacket.body["zoomRange"] as? [NSNumber], zoomRangeArray.count >= 2 {
                zoomMin = zoomRangeArray[0].floatValue
                zoomMax = zoomRangeArray[1].floatValue
            }
            var opticalZooms: [Float] = []
            if let arr = dataPacket.body["opticalZooms"] as? [NSNumber] {
                opticalZooms = arr.map { $0.floatValue }
            }
            let activeZoom = (dataPacket.body["activeZoom"] as? NSNumber)?.floatValue
            
            Logger.services.info("WebcamService: stream started, codec=\(codec.rawValue) rotation=\(rotation) zoom=[\(zoomMin),\(zoomMax)] optical=\(opticalZooms.count)")
            
            if case .requestSent(let d, _) = streamState, d.id == device.id {
                // Initial stream start
                streamState = .streaming(device: d, codec: codec)
                availableCameras = cameras
                setupAudioConverter()
                openDecoder(codec: codec)
                DispatchQueue.main.async {
                    self.showPreviewWindow(deviceName: d.name, rotation: rotation, cameras: cameras)
                    self.previewWindowController?.updateZoomRange(zoomMin, zoomMax, opticalZooms, activeZoom: activeZoom)
                    self.previewWindowController?.updateFlashAvailable(flashAvailable)
                    self.previewWindowController?.updateFlashState(flashActive)
                }
            } else if case .streaming(let d, _) = streamState, d.id == device.id {
                // Camera-switch or rotation update: update metadata without restarting the stream.
                // Only refresh the camera list when Android actually sends one (non-empty),
                // so pure rotation-update packets don't clear the picker.
                if !cameras.isEmpty { availableCameras = cameras }
                let newCameras = availableCameras
                DispatchQueue.main.async {
                    self.previewWindowController?.applyRotation(rotation)
                    if !cameras.isEmpty {
                        self.previewWindowController?.updateCameras(newCameras)
                    }
                    self.previewWindowController?.updateZoomRange(zoomMin, zoomMax, opticalZooms, activeZoom: activeZoom)
                    self.previewWindowController?.updateFlashAvailable(flashAvailable)
                    self.previewWindowController?.updateFlashState(flashActive)
                }
            }
        } else {
            if let error = dataPacket.body["error"] as? String {
                Logger.services.error("WebcamService: stream_status error=\(error, privacy: .public)")
                DispatchQueue.main.async { self.showErrorAlert(message: error, deviceName: device.name) }
            } else {
                Logger.services.info("WebcamService: stream stopped by remote")
            }
            teardown()
        }
        
        return true
    }
    
    public func setup(for device: Device) {
        // User-initiated only; no auto-start on connect.
    }
    
    public func cleanup(for device: Device) {
        switch streamState {
        case .requestSent(let d, _) where d.id == device.id,
                .streaming(let d, _)  where d.id == device.id:
            teardown()
        default:
            break
        }
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard incomingEnabled else { return [] }
        guard device.pairingStatus == .Paired else { return [] }
        guard device.incomingCapabilities.contains(DataPacket.webcamRequestStreamPacketType) else { return [] }
        
        switch streamState {
        case .idle:
            return [ServiceAction(id: ActionId.startWebcam.rawValue, title: "Use as Webcam", description: "Stream the phone camera to this Mac", service: self, device: device)]
        case .streaming(let d, _) where d.id == device.id:
            return [ServiceAction(id: ActionId.stopWebcam.rawValue, title: "Stop Webcam", description: "Stop streaming the phone camera", service: self, device: device)]
        case .requestSent(let d, _) where d.id == device.id:
            return [ServiceAction(id: ActionId.stopWebcam.rawValue, title: "Stop Webcam", description: "Cancel the pending webcam request", service: self, device: device)]
        default:
            return []
        }
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        guard let actionId = ActionId(rawValue: id) else { return }
        switch actionId {
        case .startWebcam: startStream(for: device)
        case .stopWebcam:  stopStream(for: device)
        }
    }
    
    
    // MARK: Stream start / stop
    
    private func startStream(for device: Device, camera: String = "back") {
        guard case .idle = streamState else { return }
        streamCamera = camera
        streamGeneration += 1
        
        openUDPSocket { [weak self] port in
            guard let self = self else { return }
            self.streamState = .requestSent(device: device, port: port)
            let packet = DataPacket.webcamRequestStreamPacket(
                addresses: self.localIPv4Addresses(),
                port: port,
                width: 1280, height: 720, fps: 30,
                camera: self.streamCamera
            )
            device.send(packet)
            Logger.services.info("WebcamService: sent request_stream camera=\(self.streamCamera) udp port=\(port)")
        }
    }
    
    /// Sends a switch_camera packet while the stream is active.
    /// Android switches the camera live and replies with a new stream_status containing
    /// the updated rotation; no stop/restart needed on the macOS side.
    private func sendCameraControl(camera: String? = nil, zoom: Float? = nil, flash: Bool? = nil, for device: Device) {
        guard case .streaming = streamState else { return }
        if let camera = camera { streamCamera = camera }
        device.send(DataPacket.webcamCameraControlPacket(camera: camera, zoom: zoom, flash: flash))
        Logger.services.info("WebcamService: sent camera_control → camera=\(String(describing: camera)) zoom=\(String(describing: zoom)) flash=\(String(describing: flash))")
    }
    
    private func stopStream(for device: Device) {
        device.send(DataPacket.webcamStopPacket())
        Logger.services.info("WebcamService: sent stop request")
        teardown()
    }
    
    
    // MARK: UDP socket
    
    /// Opens a POSIX UDP socket bound to an OS-assigned port.
    /// Uses DispatchSource on .main so all datagram handling is on the main queue —
    /// no extra synchronisation needed before touching WebcamService state or UI.
    private func openUDPSocket(completion: @escaping (UInt16) -> Void) {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            Logger.services.error("WebcamService: socket() failed errno=\(errno)")
            return
        }
        
        // SO_REUSEADDR avoids EADDRINUSE if the port lingers after a crash
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr   = in_addr(s_addr: INADDR_ANY)
        addr.sin_port   = 0  // let the OS pick an ephemeral port
        
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Logger.services.error("WebcamService: bind() failed errno=\(errno)")
            Darwin.close(sock)
            return
        }
        
        // Query the OS-assigned port
        var assigned = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &addrLen)
            }
        }
        let port = UInt16(bigEndian: assigned.sin_port)
        guard port > 0 else {
            Logger.services.error("WebcamService: getsockname() returned port 0")
            Darwin.close(sock)
            return
        }
        
        udpSocket = sock
        
        // DispatchSource fires on .main whenever a datagram is available to read
        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: .main)
        src.setEventHandler { [weak self] in self?.readUDPDatagram() }
        src.setCancelHandler { Darwin.close(sock) }
        src.resume()
        udpSource = src
        
        Logger.services.info("WebcamService: UDP socket ready on port \(port)")
        completion(port)
    }
    
    private func readUDPDatagram() {
        guard udpSocket >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = recv(udpSocket, &buf, buf.count, 0)
        guard n > 0 else { return }
        handleDatagram(Data(buf[..<n]))
    }
    
    
    // MARK: Frame header & reassembly
    
    private struct FrameHeader {
        let sequenceNumber: UInt32
        let ptsMs: UInt32
        let frameTotalSize: UInt32
        let fragmentOffset: UInt32
        let isKeyframe: Bool
        let isLastFragment: Bool
        let streamType: UInt8  // 0=primary video, 1=desk video, 2=audio
    }
    
    private static let headerSize = 18
    
    private func parseHeader(_ data: Data) -> FrameHeader? {
        guard data.count >= Self.headerSize else { return nil }
        return data.withUnsafeBytes { raw in
            let seq = raw.load(fromByteOffset: 0,  as: UInt32.self).littleEndian
            let pts = raw.load(fromByteOffset: 4,  as: UInt32.self).littleEndian
            let tot = raw.load(fromByteOffset: 8,  as: UInt32.self).littleEndian
            let off = raw.load(fromByteOffset: 12, as: UInt32.self).littleEndian
            let fl  = raw.load(fromByteOffset: 16, as: UInt8.self)
            let st  = raw.load(fromByteOffset: 17, as: UInt8.self)
            return FrameHeader(
                sequenceNumber: seq,
                ptsMs:          pts,
                frameTotalSize: tot,
                fragmentOffset: off,
                isKeyframe:     fl & 0x01 != 0,
                isLastFragment: fl & 0x02 != 0,
                streamType:     st
            )
        }
    }
    
    private final class ReassemblyBuffer {
        let totalSize:  UInt32
        let ptsMs:      UInt32
        let isKeyframe: Bool
        var data:       Data
        var received:   Int = 0
        
        init(totalSize: UInt32, ptsMs: UInt32, isKeyframe: Bool) {
            self.totalSize  = totalSize
            self.ptsMs      = ptsMs
            self.isKeyframe = isKeyframe
            self.data       = Data(count: Int(totalSize))
        }
        
        /// Returns true when the frame is fully assembled.
        func insert(payload: Data, at offset: UInt32, isLast: Bool) -> Bool {
            let start = Int(offset)
            let end   = start + payload.count
            guard end <= data.count else { return false }
            data.replaceSubrange(start..<end, with: payload)
            received += payload.count
            return isLast && received == Int(totalSize)
        }
    }
    
    private func handleDatagram(_ data: Data) {
        guard let hdr = parseHeader(data) else { return }
        let payload = data.dropFirst(Self.headerSize)
        
        // streamType: 0=primary video, 1=desk video (reserved), 2=audio
        if hdr.streamType == 2 {
            handleFragment(hdr: hdr, payload: payload, reassembly: &audioReassembly, currentKey: &currentAudioFrameKey) { [weak self] buf in
                self?.decodeAudio(buf.data)
            }
        } else if hdr.streamType == 0 {
            handleFragment(hdr: hdr, payload: payload, reassembly: &videoReassembly, currentKey: &currentVideoFrameKey) { [weak self] buf in
                self?.decodeVideo(buf.data, ptsMs: buf.ptsMs, isKeyframe: buf.isKeyframe)
            }
        }
    }
    
    private func handleFragment(
        hdr: FrameHeader,
        payload: Data,
        reassembly: inout [UInt32: ReassemblyBuffer],
        currentKey: inout UInt32?,
        onComplete: (ReassemblyBuffer) -> Void
    ) {
        if hdr.fragmentOffset == 0 {
            // First fragment — start a new buffer
            currentKey = hdr.sequenceNumber
            reassembly[hdr.sequenceNumber] = ReassemblyBuffer(totalSize: hdr.frameTotalSize, ptsMs: hdr.ptsMs, isKeyframe: hdr.isKeyframe)
            // Evict stale incomplete buffers to prevent unbounded growth
            if reassembly.count > 30 { reassembly.removeAll() }
        }
        
        guard let key = currentKey, let buf = reassembly[key] else { return }
        
        if buf.insert(payload: payload, at: hdr.fragmentOffset, isLast: hdr.isLastFragment) {
            reassembly.removeValue(forKey: key)
            currentKey = nil
            onComplete(buf)
        }
    }
    
    
    // MARK: Video decoding
    
    private func openDecoder(codec: StreamCodec) {
        // VTDecompressionSession is opened lazily on the first keyframe
        // (we need SPS/PPS/VPS to build the CMFormatDescription first).
        Logger.services.info("WebcamService: decoder will open on first keyframe (\(codec.rawValue))")
    }
    
    private func decodeVideo(_ data: Data, ptsMs: UInt32, isKeyframe: Bool) {
        guard case .streaming(_, let codec) = streamState else { return }
        
        // Try to extract parameter sets from every frame — Android MediaCodec may send
        // VPS/SPS/PPS as a separate BUFFER_FLAG_CODEC_CONFIG buffer (isKeyframe=false)
        // before the first real keyframe, or may include them inline in keyframes.
        // Either way, update the format description whenever we find parameter sets.
        if let desc = extractFormatDescription(from: data, codec: codec) {
            if !cmFormatDescriptionsMatch(desc, videoFormatDescription) {
                videoFormatDescription = desc
                reopenDecompressionSession(formatDescription: desc)
                Logger.services.info("WebcamService: video format description updated")
            }
        }
        
        guard let formatDesc = videoFormatDescription, let session    = decompressionSession else {
            if isKeyframe {
                Logger.services.warning("WebcamService: keyframe dropped — no format description yet")
            }
            return
        }
        
        guard let blockBuffer = annexBToAVCC(data, codec: codec) else { return }
        
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTimeMakeWithSeconds(Double(ptsMs) / 1000.0, preferredTimescale: 90000),
            decodeTimeStamp: .invalid
        )
        var dataSize = blockBuffer.dataLength
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &dataSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sb = sampleBuffer else { return }
        
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], frameRefcon: nil, infoFlagsOut: nil)
    }
    
    private func reopenDecompressionSession(formatDescription: CMFormatDescription) {
        if let old = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(old)
            VTDecompressionSessionInvalidate(old)
            decompressionSession = nil
        }
        
        // The callback must be a C function — use Unmanaged to pass self as refCon.
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, pts, _ in
                guard status == noErr, let pixelBuffer = imageBuffer,
                      let refCon = refCon else { return }
                let svc = Unmanaged<WebcamService>.fromOpaque(refCon).takeUnretainedValue()
                let capPts = pts
                DispatchQueue.main.async {
                    svc.previewWindowController?.pushFrame(pixelBuffer, pts: capPts)
                }
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let result = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &decompressionSession
        )
        if result != noErr {
            Logger.services.error("WebcamService: VTDecompressionSessionCreate failed: \(result)")
        }
    }
    
    /// Compares two optional CMFormatDescriptions to detect stream format changes.
    private func cmFormatDescriptionsMatch(_ a: CMFormatDescription, _ b: CMFormatDescription?) -> Bool {
        guard let b = b else { return false }
        return CMFormatDescriptionEqual(a, otherFormatDescription: b)
    }
    
    
    // MARK: NAL unit helpers
    
    /// Split Annex-B stream at 4-byte start codes; returns raw NAL unit bytes (no start code).
    private func splitAnnexB(_ data: Data) -> [Data] {
        var nals:  [Data] = []
        var i     = data.startIndex
        var start = data.startIndex
        
        while i + 3 < data.endIndex {
            if data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1 {
                if i > start { nals.append(data[start..<i]) }
                start = data.index(i, offsetBy: 4)
                i = start
            } else if data[i] == 0 && data[i+1] == 0 && data[i+2] == 1 {
                if i > start { nals.append(data[start..<i]) }
                start = data.index(i, offsetBy: 3)
                i = start
            } else {
                i = data.index(after: i)
            }
        }
        if start < data.endIndex { nals.append(data[start...]) }
        return nals
    }
    
    /// Build a CMFormatDescription from SPS/PPS (H.264) or VPS/SPS/PPS (H.265) in the keyframe.
    private func extractFormatDescription(from data: Data, codec: StreamCodec) -> CMFormatDescription? {
        let nals = splitAnnexB(data)
        switch codec {
        case .h264:
            guard let sps = nals.first(where: { ($0.first.map { $0 & 0x1F } ?? 0) == 7 }),
                  let pps = nals.first(where: { ($0.first.map { $0 & 0x1F } ?? 0) == 8 })
            else { return nil }
            return sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr in
                    var ptrs: [UnsafePointer<UInt8>] = [
                        spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    ]
                    var sizes = [sps.count, pps.count]
                    var desc: CMFormatDescription?
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: &ptrs,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &desc)
                    return desc
                }
            }
        case .h265:
            guard let vps = nals.first(where: { ($0.first.map { ($0 & 0x7E) >> 1 } ?? 0) == 32 }),
                  let sps = nals.first(where: { ($0.first.map { ($0 & 0x7E) >> 1 } ?? 0) == 33 }),
                  let pps = nals.first(where: { ($0.first.map { ($0 & 0x7E) >> 1 } ?? 0) == 34 })
            else { return nil }
            return vps.withUnsafeBytes { vpsPtr in
                sps.withUnsafeBytes { spsPtr in
                    pps.withUnsafeBytes { ppsPtr in
                        var ptrs: [UnsafePointer<UInt8>] = [
                            vpsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        ]
                        var sizes = [vps.count, sps.count, pps.count]
                        var desc: CMFormatDescription?
                        CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: &ptrs,
                            parameterSetSizes: &sizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &desc)
                        return desc
                    }
                }
            }
        }
    }
    
    /// Convert Annex-B access unit to AVCC (4-byte big-endian length prefix per NAL unit).
    /// Parameter-set NALs (SPS/PPS/VPS) are excluded — they live in the CMFormatDescription.
    private func annexBToAVCC(_ data: Data, codec: StreamCodec) -> CMBlockBuffer? {
        var avcc = Data()
        for nal in splitAnnexB(data) {
            guard let first = nal.first else { continue }
            // Skip parameter sets — already encoded in the CMFormatDescription.
            switch codec {
            case .h264:
                let t = first & 0x1F
                if t == 7 || t == 8 { continue }   // SPS, PPS
            case .h265:
                let t = (first & 0x7E) >> 1
                if t == 32 || t == 33 || t == 34 { continue }  // VPS, SPS, PPS
            }
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        guard !avcc.isEmpty else { return nil }
        
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let bb = blockBuffer else { return nil }
        let copyStatus = avcc.withUnsafeBytes { src in
            CMBlockBufferReplaceDataBytes(with: src.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        return copyStatus == noErr ? bb : nil
    }
    
    
    // MARK: Audio decoding
    
    private func setupAudioConverter() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let aacFormat = AVAudioFormat(streamDescription: &asbd) else { return }
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        pcmFormat = outFormat
        audioConverter = AVAudioConverter(from: aacFormat, to: outFormat)
    }
    
    private func decodeAudio(_ data: Data) {
        guard let converter = audioConverter, let pcm = pcmFormat else { return }
        
        let inputBuffer = AVAudioCompressedBuffer(
            format: converter.inputFormat,
            packetCapacity: 1,
            maximumPacketSize: data.count
        )
        inputBuffer.packetCount = 1
        inputBuffer.byteLength = UInt32(data.count)
        data.copyBytes(to: inputBuffer.data.assumingMemoryBound(to: UInt8.self), count: data.count)
        if let desc = inputBuffer.packetDescriptions {
            desc[0] = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,  // 0 = constant frame count (use mFramesPerPacket from ASBD)
                mDataByteSize: UInt32(data.count)
            )
        }
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1024) else { return }
        var convError: NSError?
        converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        if convError == nil {
            DispatchQueue.main.async {
                self.previewWindowController?.pushAudio(outputBuffer)
            }
        }
    }
    
    
    // MARK: Preview window
    
    private func showPreviewWindow(deviceName: String, rotation: Int, cameras: [WebcamCamera]) {
        if previewWindowController == nil {
            let vc = WebcamPreviewWindowController(deviceName: deviceName)
            let gen = streamGeneration   // capture so old windows don't tear down new streams
            vc.onClose = { [weak self] in
                guard let self = self, self.streamGeneration == gen else { return }
                if case .streaming(let d, _) = self.streamState {
                    d.send(DataPacket.webcamStopPacket())
                }
                self.teardown()
            }
            vc.onCameraSwitch = { [weak self] cameraId in
                guard let self = self,
                      case .streaming(let d, _) = self.streamState else { return }
                self.sendCameraControl(camera: cameraId, for: d)
            }
            vc.onZoomChange = { [weak self] zoom in
                guard let self = self,
                      case .streaming(let d, _) = self.streamState else { return }
                self.sendCameraControl(zoom: zoom, for: d)
            }
            vc.onFlashToggle = { [weak self] active in
                guard let self = self,
                      case .streaming(let d, _) = self.streamState else { return }
                self.sendCameraControl(flash: active, for: d)
            }
            previewWindowController = vc
        }
        previewWindowController?.applyRotation(rotation)
        previewWindowController?.updateCameras(cameras)
        previewWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    
    // MARK: Teardown
    
    private func teardown() {
        udpSource?.cancel()   // cancel handler calls Darwin.close(sock)
        udpSource = nil
        udpSocket = -1
        
        videoReassembly.removeAll()
        audioReassembly.removeAll()
        currentVideoFrameKey = nil
        currentAudioFrameKey = nil
        
        if let s = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        decompressionSession     = nil
        videoFormatDescription   = nil
        audioConverter           = nil
        pcmFormat                = nil
        
        // Nil out the reference synchronously before closing so that if the
        // window's close callback fires (onClose) and calls teardown() again,
        // previewWindowController is already nil and the re-entrant call is a no-op.
        // The generation guard in onClose also prevents it from acting on new streams.
        let capturedWC = previewWindowController
        previewWindowController = nil
        streamState = .idle
        
        DispatchQueue.main.async {
            capturedWC?.close()
        }
    }
    
    
    // MARK: Network helpers
    
    /// Returns all non-loopback, non-link-local IPv4 addresses on this machine.
    private func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }
        
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let ifa = cur.pointee
            if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
                let addr = String(cString: buf)
                if addr != "127.0.0.1" && !addr.hasPrefix("169.254.") {
                    addresses.append(addr)
                }
            }
            ptr = ifa.ifa_next
        }
        return addresses
    }
    
    // MARK: Error UI
    
    private func showErrorAlert(message: String, deviceName: String) {
        let alert = NSAlert()
        alert.messageText = "Webcam Error"
        alert.informativeText = "\(deviceName): \(message)"
        alert.alertStyle = .warning
        alert.runModal()
    }
}


// MARK: - WebcamCamera

/// A camera option advertised by Android in stream_status.
struct WebcamCamera {
    let id: String
    
    init(id: String) { self.id = id }
    
    var label: String {
        switch id {
        case "back":      return "Back Camera"
        case "front":     return "Front Camera"
        case "ultrawide": return "Ultrawide Camera"
        case "telephoto": return "Telephoto Camera"
        default:          return id.capitalized
        }
    }
}


// MARK: - DataPacket (Webcam)

fileprivate extension DataPacket {
    
    static let webcamRequestStreamPacketType = "kdeconnect.webcam.request_stream"
    static let webcamStreamStatusPacketType  = "kdeconnect.webcam.stream_status"
    static let webcamCameraControlPacketType  = "kdeconnect.webcam.camera_control"
    
    static func webcamRequestStreamPacket(addresses: [String], port: UInt16, width: Int, height: Int, fps: Int, camera: String) -> DataPacket {
        DataPacket(type: webcamRequestStreamPacketType, body: [
            "addresses": addresses as AnyObject,
            "port":      NSNumber(value: port),
            "width":     NSNumber(value: width),
            "height":    NSNumber(value: height),
            "fps":       NSNumber(value: fps),
            "bitrate":   NSNumber(value: -1),
            "codec":     "h265" as AnyObject,
            "camera":    camera as AnyObject
        ])
    }
    
    static func webcamStopPacket() -> DataPacket {
        DataPacket(type: webcamRequestStreamPacketType, body: [
            "stop": true as AnyObject
        ])
    }
    
    static func webcamCameraControlPacket(camera: String? = nil, zoom: Float? = nil, flash: Bool? = nil) -> DataPacket {
        var body: [String: AnyObject] = [:]
        if let camera = camera { body["camera"] = camera as AnyObject }
        if let zoom = zoom { body["zoom"] = NSNumber(value: zoom) }
        if let flash = flash { body["flash"] = NSNumber(value: flash) }
        return DataPacket(type: webcamCameraControlPacketType, body: body)
    }
}


// MARK: - WebcamPreviewWindowController

/// Renders decoded video frames and plays decoded audio during a webcam stream session.
///
/// Video path:  CVPixelBuffer → CMSampleBuffer → AVSampleBufferDisplayLayer (via WebcamPreviewModel)
/// Audio path:  AVAudioPCMBuffer → AVAudioPlayerNode → AVAudioEngine output
final class WebcamPreviewWindowController: NSWindowController, NSWindowDelegate {
    
    var onClose: (() -> Void)?
    var onCameraSwitch: ((String) -> Void)?
    var onZoomChange: ((Float) -> Void)?
    var onFlashToggle: ((Bool) -> Void)?
    
    private let model: WebcamPreviewModel
    private let audioEngine = AVAudioEngine()
    private let playerNode  = AVAudioPlayerNode()
    
    init(deviceName: String) {
        model = WebcamPreviewModel()
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "\(deviceName) Webcam"
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        
        super.init(window: window)
        
        model.onCameraSwitch = { [weak self] id     in self?.onCameraSwitch?(id) }
        model.onZoomChange   = { [weak self] zoom   in self?.onZoomChange?(zoom) }
        model.onFlashToggle  = { [weak self] active in self?.onFlashToggle?(active) }
        
        let hosting = NSHostingController(rootView: WebcamPreviewContentView(model: model))
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1280, height: 720))
        window.center()
        window.delegate = self
        
        setupAudioEngine()
    }
    
    required init?(coder: NSCoder) { fatalError("not used") }
    
    // MARK: Public API
    
    func applyRotation(_ degrees: Int) {
        model.rotation = degrees
    }
    
    func updateCameras(_ cameras: [WebcamCamera]) {
        model.cameras = cameras
    }
    
    func updateZoomRange(_ min: Float, _ max: Float, _ levels: [Float], activeZoom: Float? = nil) {
        model.zoomMin = min
        model.zoomMax = max
        model.zoomLevels = levels
        if let zoom = activeZoom {
            model.currentZoom = zoom
        }
    }
    
    func updateFlashAvailable(_ available: Bool) {
        model.flashAvailable = available
    }
    
    func updateFlashState(_ active: Bool) {
        model.flashActive = active
    }
    
    func pushFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        model.pushFrame(pixelBuffer, pts: pts)
    }
    
    func pushAudio(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        if !playerNode.isPlaying { playerNode.play() }
    }
    
    // MARK: Audio
    
    private func setupAudioEngine() {
        let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: pcmFormat)
        try? audioEngine.start()
    }
    
    // MARK: NSWindowDelegate
    
    func windowWillClose(_ notification: Notification) {
        audioEngine.stop()
        onClose?()
    }
}
