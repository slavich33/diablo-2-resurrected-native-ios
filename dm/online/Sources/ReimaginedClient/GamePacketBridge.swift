import Foundation

public typealias NativePacketLengthResolver = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt32
) -> Int32

/// Caller-serialized C polling adapter. The callback runs synchronously on the
/// caller's thread, so a future engine resolver need not touch guest state from
/// a Network.framework callback. No raw TCP connection is implicitly attached.
private final class NativePacketBridge {
    let decoder: GamePacketStream
    var pending: Data?
    var kind: Int32 = 0
    var error: Int32 = 0
    var ended = false

    init(resolve: @escaping NativePacketLengthResolver, context: UnsafeMutableRawPointer?) {
        decoder = GamePacketStream { header in
            let count = header.withUnsafeBytes { resolve(context, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(header.count)) }
            if count > 0 { return .length(Int(count)) }
            if count == 0 { return .needMore }
            return count == -2 ? .invalid : .unsupported
        }
    }

    init(decoder: GamePacketStream) { self.decoder = decoder }

    func record(_ failure: Error) {
        if let streamError = failure as? GamePacketStreamError {
            switch streamError {
            case .unsupportedPacket: error = 1
            case .truncatedPacket: error = 3
            default: error = 2
            }
        } else if let frameError = failure as? LoaderFrameError {
            switch frameError {
            case .invalidSize, .lengthMismatch, .carrierTooLarge: error = 2
            default: error = 4
            }
        } else { error = 4 }
    }
}

@_cdecl("dm_online_packets_open")
public func nativePacketsOpen(_ resolve: NativePacketLengthResolver?, _ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let resolve else { return nil }
    return Unmanaged.passRetained(NativePacketBridge(resolve: resolve, context: context)).toOpaque()
}

/// Supported exact-build game packets, after transport decoding. Unverified
/// formats fail visibly; this does not enable raw TCP, system routing or admission.
@_cdecl("dm_online_packets_open_stock_94012")
public func nativeStockPacketsOpen() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(NativePacketBridge(
        decoder: GamePacketStream(resolvePacketLength: StockServerPacketLengths.resolve)
    )).toOpaque()
}

@_cdecl("dm_online_packets_append")
public func nativePacketsAppend(_ handle: UnsafeMutableRawPointer?, _ bytes: UnsafeRawPointer?, _ count: UInt32) -> Int32 {
    guard let handle, let bytes, count > 0 else { return -4 }
    let bridge = Unmanaged<NativePacketBridge>.fromOpaque(handle).takeUnretainedValue()
    guard bridge.error == 0 else { return -3 }
    guard !bridge.ended else { return -2 }
    guard count <= GamePacketStream.maximumBufferedBytes else { return -5 }
    do { try bridge.decoder.append(Data(bytes: bytes, count: Int(count))); return 0 }
    catch GamePacketStreamError.bufferFull { return -1 }
    catch { bridge.record(error); return -3 }
}

@_cdecl("dm_online_packets_end")
public func nativePacketsEnd(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let handle else { return -4 }
    let bridge = Unmanaged<NativePacketBridge>.fromOpaque(handle).takeUnretainedValue()
    bridge.ended = true; bridge.decoder.endOfInput()
    return bridge.error == 0 ? 0 : -3
}

@_cdecl("dm_online_packets_read")
public func nativePacketsRead(_ handle: UnsafeMutableRawPointer?, _ bytes: UnsafeMutableRawPointer?,
                              _ capacity: UInt32, _ kind: UnsafeMutablePointer<Int32>?) -> Int32 {
    kind?.pointee = 0
    guard let handle, let bytes, capacity > 0, let kind else { return -4 }
    let bridge = Unmanaged<NativePacketBridge>.fromOpaque(handle).takeUnretainedValue()
    guard bridge.error == 0 else { return -3 }
    if bridge.pending == nil {
        do {
            guard let packet = try bridge.decoder.nextPacket() else { return bridge.ended ? -2 : -1 }
            switch packet {
            case .control(let control): bridge.pending = control.gameCarrier(); bridge.kind = 2
            case .loader(let frame): bridge.pending = try frame.gameCarrier(); bridge.kind = 3
            case .gameplay(let gameplay): bridge.pending = gameplay; bridge.kind = 1
            }
        } catch { bridge.record(error); return -3 }
    }
    guard let packet = bridge.pending else { return -3 }
    // Preserve the packet for a retry with a larger engine buffer.
    guard packet.count <= capacity else { return -5 }
    packet.withUnsafeBytes { bytes.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
    kind.pointee = bridge.kind
    bridge.pending = nil
    return Int32(packet.count)
}

@_cdecl("dm_online_packets_error")
public func nativePacketsError(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let handle else { return -4 }
    return Unmanaged<NativePacketBridge>.fromOpaque(handle).takeUnretainedValue().error
}

@_cdecl("dm_online_packets_release")
public func nativePacketsRelease(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    _ = Unmanaged<NativePacketBridge>.fromOpaque(handle).takeRetainedValue()
}
