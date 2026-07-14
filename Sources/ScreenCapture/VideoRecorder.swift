import AppKit
import ScreenCaptureKit
import AVFoundation

final class VideoRecorder: NSObject, @unchecked Sendable {

    private var stream:        SCStream?
    private var writer:        AVAssetWriter?
    private var videoInput:    AVAssetWriterInput?
    private var pixelAdaptor:  AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL:     URL?
    private var startPTS:      CMTime = .invalid
    private var isRecording    = false

    // MARK: - Start

    func start(sourceRect: CGRect? = nil) async throws {
        guard !isRecording else { return }

        // Track partial-init state so we can unwind cleanly if any step throws.
        // Without this, a failed startCapture left writer/input in a half-built
        // state that broke the next start() call.
        var cleanupOnFailure = true
        defer {
            if cleanupOnFailure { resetState() }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw RecordingError.noDisplay }

        let scale  = NSScreen.main?.backingScaleFactor ?? 2.0
        let width:  Int
        let height: Int

        if let r = sourceRect {
            width  = Int(r.width  * scale)
            height = Int(r.height * scale)
        } else {
            width  = display.width  * Int(scale)
            height = display.height * Int(scale)
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenCapture-\(Int(Date().timeIntervalSince1970)).mov")
        outputURL = tmp
        startPTS  = .invalid

        let w = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let codec: AVVideoCodecType = Preferences.shared.videoCodec == .h264 ? .h264 : .hevc
        let settings: [String: Any] = [
            AVVideoCodecKey:  codec,
            AVVideoWidthKey:  width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey  as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        w.add(input)
        w.startWriting()
        w.startSession(atSourceTime: .zero)
        writer       = w
        videoInput   = input
        pixelAdaptor = adaptor

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width       = width
        config.height      = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        if let r = sourceRect {
            config.sourceRect = r
        }

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())
        try await s.startCapture()
        stream      = s
        isRecording = true
        cleanupOnFailure = false

        NSLog("[VideoRecorder] Recording started → \(tmp.path)")
    }

    /// Tear down any partial recording state — used by the start() error path and
    /// after fatal stream errors so the next start() call begins from a clean slate.
    private func resetState() {
        if let s = stream {
            Task { try? await s.stopCapture() }
        }
        stream       = nil
        if let i = videoInput, !i.isReadyForMoreMediaData == false { i.markAsFinished() }
        videoInput   = nil
        pixelAdaptor = nil
        if let w = writer, w.status == .writing {
            w.cancelWriting()
        }
        writer       = nil
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL    = nil
        startPTS     = .invalid
        isRecording  = false
    }

    // MARK: - Stop

    func stop() async -> URL? {
        guard isRecording, let stream else { return nil }
        isRecording  = false
        self.stream  = nil

        try? await stream.stopCapture()
        videoInput?.markAsFinished()

        return await withCheckedContinuation { cont in
            writer?.finishWriting { [weak self] in
                let url = self?.outputURL
                NSLog("[VideoRecorder] Recording saved → \(url?.path ?? "nil")")
                cont.resume(returning: url)
            }
        }
    }

    var active: Bool { isRecording }
}

// MARK: - SCStreamOutput / SCStreamDelegate

extension VideoRecorder: SCStreamOutput, SCStreamDelegate {

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              isRecording,
              let input = videoInput, input.isReadyForMoreMediaData,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startPTS == .invalid { startPTS = pts }
        let relativePTS = CMTimeSubtract(pts, startPTS)
        pixelAdaptor?.append(pixelBuffer, withPresentationTime: relativePTS)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[VideoRecorder] Stream stopped with error: \(error)")
        resetState()
        // Surface the failure in the menu bar so the user sees we're no longer recording.
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.setRecording(false)
            RecordingOverlay.shared.hide()
        }
    }
}

// MARK: - Error

enum RecordingError: Error { case noDisplay }
