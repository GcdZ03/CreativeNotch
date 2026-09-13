import Foundation

/// What is capturing right now.
///
/// The privacy tell: something is using the microphone or the camera, shown in
/// the notch, next to the hardware it is about.
public struct CaptureUse: Equatable, Sendable {
    public var microphone: Bool
    public var camera: Bool

    public init(microphone: Bool = false, camera: Bool = false) {
        self.microphone = microphone
        self.camera = camera
    }

    public static let none = CaptureUse()

    public var isAnythingCapturing: Bool { microphone || camera }
}

/// Which glyph the indicator shows.
///
/// Both at once is one state rather than two overlapping badges: the closed
/// notch has a single trailing slot, and two icons competing for it is how the
/// badge width becomes a fitted measurement -- which `NotchGeometry` documents
/// at length as the thing to avoid.
public enum CaptureIndicator: Equatable, Sendable {
    case none
    case microphone
    case camera
    case both

    public init(_ use: CaptureUse) {
        switch (use.microphone, use.camera) {
        case (false, false): self = .none
        case (true, false):  self = .microphone
        case (false, true):  self = .camera
        case (true, true):   self = .both
        }
    }
}
