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
public struct LineBuffer: Equatable, Sendable {

    private var buffer = ""

    public init() {}

    /// What is held back awaiting its newline.
    public var pending: String { buffer }

    /// Appends a chunk and returns every complete line it completed.
    ///
    /// Blank lines are dropped rather than returned as empty strings —
    /// they carry no payload, and letting them through only moves the
    /// special case into the decoder.
    public mutating func append(_ chunk: String) -> [String] {
        buffer += chunk

        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    /// Discards any partial line.
    ///
    /// Called when the helper dies. Without it, the dead process's
    /// half-written line would be glued to the new process's first line,
    /// corrupting exactly one payload per restart.
    public mutating func reset() {
        buffer = ""
    }
}
