import CryptoKit
import Foundation
import zlib

/// Consumes only the shared parser's validated selected extent. It never opens
/// another archive, interprets ZIP headers, or calls an archive library.
enum ZIPContentExtraction {
    static func extract(record: ZIPCentralRecord, layout: ZIPRecordLayout,
                        reader: any ZIPPositionalReading, destination: Int32,
                        maximumBytes: UInt64, checkpoint: () throws -> Void) throws -> Data {
        try extract(record: record, layout: layout, reader: reader, maximumBytes: maximumBytes,
                    checkpoint: checkpoint, consume: { try ContentFileIO.write($0, to: destination) })
    }

    /// An already-admitted mutation worker can verify a newly added member by
    /// consuming/discarding chunks without staging a second extracted copy.
    static func extract(record: ZIPCentralRecord, layout: ZIPRecordLayout,
                        reader: any ZIPPositionalReading, maximumBytes: UInt64,
                        checkpoint: () throws -> Void, consume consumer: (Data) throws -> Void) throws -> Data {
        guard record.kind == .file, record.flags & 0x2041 == 0,
              record.method == 0 || record.method == 8 else { throw ItemContentError.unsupportedType }
        guard record.uncompressedSize <= maximumBytes,
              layout.payloadRange.length == record.compressedSize else { throw ItemContentError.limitExceeded }
        var crc = ZIPCRC32(), digest = SHA256(), emitted: UInt64 = 0
        func consume(_ data: Data) throws {
            try checkpoint()
            let total = emitted.addingReportingOverflow(UInt64(data.count))
            guard !total.overflow, total.partialValue <= record.uncompressedSize,
                  total.partialValue <= maximumBytes else { throw ItemContentError.corruptContent }
            try crc.update(data); digest.update(data: data)
            try consumer(data); emitted = total.partialValue
        }
        if record.method == 0 {
            guard record.compressedSize == record.uncompressedSize else { throw ItemContentError.corruptContent }
            var offset: UInt64 = 0
            while offset < record.compressedSize {
                try checkpoint()
                let count = Int(min(UInt64(ContentFileIO.chunkSize), record.compressedSize - offset))
                let data = try reader.read(offset: layout.payloadRange.offset + offset, count: count)
                guard data.count == count else { throw ItemContentError.corruptContent }
                try consume(data); offset += UInt64(count)
            }
        } else {
            guard record.compressedSize > 0 else { throw ItemContentError.corruptContent }
            let input = UnsafeMutablePointer<UInt8>.allocate(capacity: ContentFileIO.chunkSize)
            let output = UnsafeMutablePointer<UInt8>.allocate(capacity: ContentFileIO.chunkSize)
            defer { input.deallocate(); output.deallocate() }
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw ItemContentError.corruptContent
            }
            defer { inflateEnd(&stream) }
            var loaded: UInt64 = 0
            while true {
                try checkpoint()
                if stream.avail_in == 0, loaded < record.compressedSize {
                    let count = Int(min(UInt64(ContentFileIO.chunkSize), record.compressedSize - loaded))
                    let data = try reader.read(offset: layout.payloadRange.offset + loaded, count: count)
                    guard data.count == count else { throw ItemContentError.corruptContent }
                    data.copyBytes(to: input, count: count)
                    stream.next_in = input; stream.avail_in = uInt(count); loaded += UInt64(count)
                }
                // Even an exact output-size fill must drive the inflater to a
                // terminal status. A fresh buffer permits that final step;
                // consume rejects any bytes beyond the declared output size.
                stream.next_out = output; stream.avail_out = uInt(ContentFileIO.chunkSize)
                let before = stream.avail_in
                let status = inflate(&stream, Z_NO_FLUSH)
                let produced = ContentFileIO.chunkSize - Int(stream.avail_out)
                if produced > 0 { try consume(Data(bytes: output, count: produced)) }
                if status == Z_STREAM_END {
                    // zlib leaves whole trailing bytes unconsumed. This also
                    // rejects declared bytes beyond the currently loaded chunk.
                    let remaining = UInt64(stream.avail_in)
                    guard remaining <= loaded, loaded - remaining == record.compressedSize else {
                        throw ItemContentError.corruptContent
                    }
                    break
                }
                if status == Z_BUF_ERROR {
                    // New input may unblock the decoder; exhausted input cannot
                    // prove termination. Never retry the same buffers unchanged.
                    guard stream.avail_in == 0, loaded < record.compressedSize else {
                        throw ItemContentError.corruptContent
                    }
                    continue
                }
                guard status == Z_OK, produced > 0 || before != stream.avail_in else {
                    throw ItemContentError.corruptContent
                }
            }
        }
        try checkpoint()
        guard emitted == record.uncompressedSize, crc.value == record.crc32 else { throw ItemContentError.corruptContent }
        return Data(digest.finalize())
    }
}
