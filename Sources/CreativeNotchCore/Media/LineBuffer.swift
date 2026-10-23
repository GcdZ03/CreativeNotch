import Foundation

/// Reassembles newline-delimited text arriving in arbitrary chunks.
///
/// `FileHandle.readabilityHandler` delivers whatever bytes are available,
/// not whole lines. A payload carrying base64 artwork is far larger than a
/// pipe buffer, so splitting is the normal case rather than an edge one.
///
/// Kept separate from the reader, and pure, because the failure mode is
/// intermittent: a naive reader works perfectly until a line happens to
/// straddle a chunk boundary, which correlates with nothing a user can
/// describe.
///
/// **Bytes in, strings out.** A chunk boundary falls between bytes, not
/// characters, so a title with an emoji can arrive as two halves of
/// invalid UTF-8. Decoding each chunk on its own (as this once took
/// `String` chunks to do) turned that into a `nil` and dropped the whole
/// chunk, newline and all. So the buffer holds raw bytes, splits on 0x0A —
/// which UTF-8 never uses inside a multibyte sequence, so the split can
/// never land mid-character — and decodes only complete lines.
public struct LineBuffer: Equatable, Sendable {

    private var buffer = Data()

    /// How far into `buffer` is already known to hold no newline.
    ///
    /// Without it, every chunk rescans everything held back before it, and
    /// a 1 MB artwork line delivered in pipe-sized pieces costs the square
    /// of its length to find one newline.
    private var scanned = 0

    /// Total bytes examined for a newline over this buffer's life. Internal,
    /// for the test that proves each byte is looked at once.
    private(set) var bytesScanned = 0

    public init() {}

    /// What is held back awaiting its newline, decoded leniently. For
    /// inspection only; the bytes themselves are what get completed.
    public var pending: String { String(decoding: buffer, as: UTF8.self) }

    /// How many bytes are held back awaiting their newline. Bytes, not
    /// characters, because the reader's cap is a memory bound.
    public var pendingByteCount: Int { buffer.count }

    /// Appends a chunk and returns every complete line it completed.
    ///
    /// Blank lines are dropped rather than returned as empty strings —
    /// they carry no payload, and letting them through only moves the
    /// special case into the decoder. A complete line that is not valid
    /// UTF-8 is dropped too: the helper emits JSON from
    /// `NSJSONSerialization`, so such a line is corrupt, not a payload.
    public mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)

        var lines: [String] = []
        let start = buffer.startIndex
        var lineStart = start
        var cursor = start + scanned
        while let newline = buffer[cursor...].firstIndex(of: 0x0A) {
            bytesScanned += newline - cursor + 1
            if newline > lineStart, let line = String(data: buffer[lineStart..<newline], encoding: .utf8) {
                lines.append(line)
            }
            lineStart = newline + 1
            cursor = lineStart
        }
        bytesScanned += buffer.endIndex - cursor

        // Consumed lines are removed once per chunk, not once per line, so
        // a chunk carrying many short lines does not shift the remainder
        // down once for each of them.
        if lineStart > start {
            buffer = Data(buffer[lineStart...])
        }
        scanned = buffer.count
        return lines
    }

    /// Discards any partial line.
    ///
    /// Called when the helper dies. Without it, the dead process's
    /// half-written line would be glued to the new process's first line,
    /// corrupting exactly one payload per restart.
    public mutating func reset() {
        buffer = Data()
        scanned = 0
    }
}
