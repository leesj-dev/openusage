import Foundation
import libzstd

/// A bounded, in-process decoder for immutable Codex rollouts. Never writes decompressed history
/// to disk. One instance belongs to one synchronous parse worker.
final class ZstandardLogReader {
    private let handle: FileHandle
    private let context: OpaquePointer
    private var input = Data()
    private var inputOffset = 0
    private var atEOF = false
    private var remaining = 1

    enum ReadError: Error {
        case allocationFailed
        case invalidArchive(String)
        case truncatedArchive
    }

    init(path: String) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        guard let context = ZSTD_createDStream() else {
            try? handle.close()
            throw ReadError.allocationFailed
        }
        self.handle = handle
        self.context = context
        // Bound the decoder's history window to 128 MiB as well as its input/output buffers.
        let result = ZSTD_DCtx_setParameter(context, ZSTD_d_windowLogMax, 27)
        if ZSTD_isError(result) != 0 {
            throw ReadError.invalidArchive(String(cString: ZSTD_getErrorName(result)))
        }
    }

    deinit {
        ZSTD_freeDStream(context)
        try? handle.close()
    }

    func read(upToCount count: Int) throws -> Data? {
        var output = Data(count: count)
        let written = try output.withUnsafeMutableBytes { destination in
            var decoded = ZSTD_outBuffer(dst: destination.baseAddress, size: count, pos: 0)
            while decoded.pos < count {
                try Task.checkCancellation()
                if inputOffset == input.count && !atEOF {
                    input = try handle.read(upToCount: JSONLStreamingReader.readChunkBytes) ?? Data()
                    inputOffset = 0
                    atEOF = input.isEmpty
                }
                if atEOF && remaining == 0 { break }
                let previousOutput = decoded.pos
                let previousInput = inputOffset
                remaining = input.withUnsafeBytes { bytes in
                    var encoded = ZSTD_inBuffer(src: bytes.baseAddress, size: bytes.count, pos: inputOffset)
                    let result = ZSTD_decompressStream(context, &decoded, &encoded)
                    inputOffset = encoded.pos
                    return result
                }
                guard ZSTD_isError(remaining) == 0 else {
                    throw ReadError.invalidArchive(String(cString: ZSTD_getErrorName(remaining)))
                }
                if decoded.pos == previousOutput && inputOffset == previousInput {
                    // A complete frame followed by EOF is valid; any unfinished frame is not.
                    if atEOF && remaining == 0 { break }
                    if atEOF { throw ReadError.truncatedArchive }
                }
            }
            return decoded.pos
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }
}
