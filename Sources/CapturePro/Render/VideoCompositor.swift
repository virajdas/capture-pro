import AVFoundation
import CoreImage
import Metal

/// Carries the screen/camera track IDs and our `Compositor` into AVFoundation.
final class CaptureInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID?
    let compositor: Compositor

    init(timeRange: CMTimeRange, screenTrack: CMPersistentTrackID, cameraTrack: CMPersistentTrackID?, compositor: Compositor) {
        self.timeRange = timeRange
        self.screenTrack = screenTrack
        self.cameraTrack = cameraTrack
        self.compositor = compositor
        requiredSourceTrackIDs = ([screenTrack] + (cameraTrack.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

/// A custom video compositor: one shared Metal-backed Core Image context renders every frame
/// straight into AVFoundation's pixel buffer pool. Much cheaper than the per-frame filter API,
/// and it can read several tracks (screen + camera).
final class CaptureVideoCompositor: NSObject, AVVideoCompositing {
    static let context: CIContext = {
        let opts: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .cacheIntermediates: false,
            .name: "CapturePro",
        ]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: opts) }
        return CIContext(options: opts)
    }()

    private let queue = DispatchQueue(label: "capture.compositor", qos: .userInitiated)
    private var cancelled = false

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            if cancelled { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? CaptureInstruction,
                  let screen = request.sourceFrame(byTrackID: instruction.screenTrack),
                  let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: ExportError.failed("Missing frame"))
                return
            }
            let camera = instruction.cameraTrack.flatMap { request.sourceFrame(byTrackID: $0) }
            let image = instruction.compositor.render(source: CIImage(cvPixelBuffer: screen),
                                                      camera: camera.map { CIImage(cvPixelBuffer: $0) },
                                                      time: request.compositionTime.seconds)
            let size = request.renderContext.size
            Self.context.render(image, to: out, bounds: CGRect(origin: .zero, size: size),
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelled = true
        queue.async { self.cancelled = false }
    }
}
