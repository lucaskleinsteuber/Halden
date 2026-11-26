import Foundation
import HaldenWatchProtocol
import Testing

@Suite("Apple Watch Bridge Protocol")
struct WatchBridgeTests {
    @Test("All WatchCommand variants encode and decode cleanly")
    func commandRoundtrip() {
        let commands: [WatchCommand] = [
            .shutter, .timer3s, .flipCamera, .setZoom(2.5), .requestState,
        ]
        for cmd in commands {
            let decoded = WatchCommand.fromMessage(cmd.toMessage())
            #expect(decoded == cmd)
        }
        #expect(WatchCommand.fromMessage(["kind": "other"]) == nil)
        #expect(WatchCommand.fromMessage(["kind": "cmd", "command": "zoom", "zoom": Double.nan]) == nil)
    }

    @Test("WatchCameraState encodes and decodes over WatchConnectivity message dictionaries")
    func stateRoundtrip() {
        let state = WatchCameraState(
            cameraOpen: true, mode: "photo", zoom: 2.0, minZoom: 0.5, maxZoom: 10.0,
            isFront: false, isRecording: false, countdown: 3)
        let decoded = WatchCameraState.fromMessage(state.toMessage())
        #expect(decoded == state)
        #expect(WatchCameraState.fromMessage(["kind": "state"]) == nil)
    }

    @Test("Frame throttler caps 60 fps flood to ~8 fps and drops while offline or busy")
    func frameThrottling() {
        var throttler = WatchFrameThrottler(maxFPS: 8.0)
        // Simulate 1 second at 60 fps (60 frames, step 1/60 s).
        var sent = 0
        for i in 0..<60 {
            let t = Double(i) / 60.0
            if throttler.shouldSendFrame(now: t, isReachable: true, inFlight: false) {
                sent += 1
            }
        }
        #expect(sent >= 7 && sent <= 9, "expected ~8 fps, got \(sent)")
        #expect(throttler.sentCount == sent)
        #expect(throttler.droppedCount == 60 - sent)

        // Never sends while unreachable or in-flight.
        let offline = throttler.shouldSendFrame(now: 10.0, isReachable: false, inFlight: false)
        let busy = throttler.shouldSendFrame(now: 10.0, isReachable: true, inFlight: true)
        #expect(!offline)
        #expect(!busy)
    }

    @Test("Quality adapts down when JPEG exceeds byte budget and gently recovers when small")
    func payloadQualityAdaptation() {
        var throttler = WatchFrameThrottler()
        let initial = throttler.jpegQuality
        throttler.recordPayloadSize(WatchFrameThrottler.maxPayloadBytes + 8000)
        #expect(throttler.jpegQuality < initial)

        let lowered = throttler.jpegQuality
        throttler.recordPayloadSize(6000)
        #expect(throttler.jpegQuality > lowered)
    }

    @Test("Digital Crown zoom clamps to camera bounds and formats labels crisply")
    func crownZoomClamping() {
        #expect(WatchCrownZoom.clamped(0.1, minZoom: 0.5, maxZoom: 10) == 0.5)
        #expect(WatchCrownZoom.clamped(25.0, minZoom: 0.5, maxZoom: 10) == 10.0)
        #expect(WatchCrownZoom.clamped(2.34, minZoom: 0.5, maxZoom: 10) == 2.3)
        #expect(WatchCrownZoom.label(for: 1.0) == "1×")
        #expect(WatchCrownZoom.label(for: 0.5) == "0.5×")
        #expect(WatchCrownZoom.label(for: 2.44) == "2.4×")
    }
}
