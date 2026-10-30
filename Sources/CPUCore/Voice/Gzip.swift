import Foundation
import zlib

/// gzip for the Doubao speech protocol, whose frames carry gzip-compressed payloads.
enum Gzip {
    static func compress(_ data: Data) -> Data {
        var stream = z_stream()
        // windowBits 31 = 15 + 16: write a gzip header and trailer.
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return Data()
        }
        defer { deflateEnd(&stream) }
        return run(data, stream: &stream) { deflate(&$0, Z_FINISH) }
    }

    static func decompress(_ data: Data) -> Data? {
        var stream = z_stream()
        // windowBits 47 = 15 + 32: accept gzip or zlib headers.
        guard inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }
        let output = run(data, stream: &stream) { inflate(&$0, Z_NO_FLUSH) }
        return output.isEmpty && !data.isEmpty ? nil : output
    }

    private static func run(_ input: Data, stream: inout z_stream, step: (inout z_stream) -> Int32) -> Data {
        var output = Data()
        var input = input
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        input.withUnsafeMutableBytes { (source: UnsafeMutableRawBufferPointer) in
            stream.next_in = source.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(source.count)
            var status: Int32 = Z_OK
            repeat {
                buffer.withUnsafeMutableBytes { target in
                    stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunk)
                    status = step(&stream)
                    output.append(target.bindMemory(to: UInt8.self).baseAddress!, count: chunk - Int(stream.avail_out))
                }
            } while status == Z_OK && (stream.avail_in > 0 || stream.avail_out == 0)
        }
        return output
    }
}
