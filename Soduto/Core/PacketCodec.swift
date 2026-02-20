//
//  PacketCodec.swift
//  Soduto
//
//  Created by Sannidhya Roy on 15/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import NIOCore
import NIOFoundationCompat

// MARK: - Packet Decoder

/// Decodes newline-delimited JSON packets from a byte stream.
///
/// KDE Connect protocol uses JSON packets terminated by a newline (`\n`).
/// This decoder buffers incoming data until a complete packet is found,
/// then passes the raw Data to the next handler for JSON parsing.
final class KDEConnectPacketDecoder: ByteToMessageDecoder {
    typealias InboundOut = Data
    
    private static let delimiter: UInt8 = 0x0A // '\n'
    
    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Look for newline delimiter
        guard let delimiterIndex = buffer.readableBytesView.firstIndex(of: Self.delimiter) else {
            // No complete packet yet, need more data
            return .needMoreData
        }
        
        // Calculate the length including the delimiter
        let packetLength = delimiterIndex - buffer.readableBytesView.startIndex + 1
        
        // Read the packet data (excluding the delimiter for parsing)
        guard let packetData = buffer.readData(length: packetLength) else {
            return .needMoreData
        }
        
        // Remove the trailing newline before passing to handler
        let trimmedData = packetData.dropLast()
        
        // Fire the packet data to the next handler
        context.fireChannelRead(self.wrapInboundOut(Data(trimmedData)))
        
        return .continue
    }
    
    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        // Try to decode any remaining data
        return try decode(context: context, buffer: &buffer)
    }
}

// MARK: - Packet Encoder

/// Encodes DataPacket objects to newline-delimited JSON bytes.
///
/// This encoder serializes DataPacket using its built-in `serialize()` method,
/// which already appends the newline delimiter.
final class KDEConnectPacketEncoder: MessageToByteEncoder {
    typealias OutboundIn = DataPacket
    
    func encode(data: DataPacket, out: inout ByteBuffer) throws {
        let bytes = try data.serialize()
        out.writeBytes(bytes)
    }
}

// MARK: - Raw Data Encoder

/// Encodes raw Data to the byte stream.
///
/// Used for sending pre-serialized packet data.
final class RawDataEncoder: MessageToByteEncoder {
    typealias OutboundIn = Data
    
    func encode(data: Data, out: inout ByteBuffer) throws {
        out.writeBytes(data)
    }
}
