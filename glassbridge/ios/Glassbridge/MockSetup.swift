#if DEBUG
import Foundation
import UIKit
import MWDATCore
import MWDATMockDevice

/// Spins up a simulated Ray-Ban Meta inside MockDeviceKit so the rest of the app
/// behaves as if a real device is paired, donned, and streaming. Used in the
/// simulator + DEBUG to bypass the broken Meta AI permission flow.
enum MockSetup {
    private(set) static var didSetup = false
    private(set) static var mockGlasses: (any MockRaybanMeta)?
    private(set) static var stubImageURL: URL?

    /// Always-safe: just creates a stub image we can use even when Wearables isn't
    /// configured (e.g. on the simulator where configure() fatals).
    static func prepareStubImage() {
        #if targetEnvironment(simulator)
        if stubImageURL == nil {
            stubImageURL = makeStubImageJPEG()
            print("[MockSetup] Stub image at \(stubImageURL!.path)")
        }
        #endif
    }

    /// Full setup including MockDeviceKit. Requires Wearables.configure() to have
    /// succeeded first (so it's safe to access Wearables.shared from observers).
    static func setupIfSimulatorDebug() {
        #if targetEnvironment(simulator)
        guard !didSetup else { return }
        didSetup = true
        prepareStubImage()

        let kit = MockDeviceKit.shared
        kit.enable(config: MockDeviceKitConfig(
            initiallyRegistered: true,
            initialPermissionsGranted: true
        ))
        let glasses = kit.pairRaybanMeta()
        self.mockGlasses = glasses
        if let url = stubImageURL {
            glasses.services.camera.setCapturedImage(fileURL: url)
        }
        glasses.powerOn()
        glasses.unfold()
        glasses.don()
        print("[MockSetup] Paired mock Ray-Ban + donned")
        #endif
    }

    /// Read the stub image bytes for the automated test path that bypasses
    /// Wearables entirely.
    static func stubImageData() -> Data? {
        prepareStubImage()
        guard let url = stubImageURL else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Generate a recognizable test image (colored gradient + label) and return its URL.
    private static func makeStubImageJPEG() -> URL {
        let size = CGSize(width: 1024, height: 1024)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            // Vertical gradient: warm orange to deep blue. Recognizable, not random noise.
            let colors = [
                UIColor(red: 1.0, green: 0.45, blue: 0.15, alpha: 1).cgColor,
                UIColor(red: 0.05, green: 0.15, blue: 0.45, alpha: 1).cgColor,
            ] as CFArray
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors, locations: [0, 1]
            )!
            cg.drawLinearGradient(gradient,
                                  start: .zero,
                                  end: CGPoint(x: 0, y: size.height),
                                  options: [])
            // A single round object so vision has something concrete to describe.
            UIColor.white.setFill()
            cg.fillEllipse(in: CGRect(x: 412, y: 412, width: 200, height: 200))

            let text = "GLASSBRIDGE TEST" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 60, weight: .heavy),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(
                at: CGPoint(x: (size.width - textSize.width) / 2, y: 80),
                withAttributes: attrs
            )
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassbridge-stub.jpg")
        try? image.jpegData(compressionQuality: 0.85)?.write(to: url)
        return url
    }

    /// Generate a 1-second silent WAV file so the backend's audio multipart field
    /// is non-empty. Backend's `text_override` makes Whisper ignore this audio.
    static func silentWAV() -> Data {
        let sampleRate: UInt32 = 16_000
        let samples: UInt32 = sampleRate
        let dataBytes: UInt32 = samples * 2
        var d = Data()
        // RIFF header
        d.append("RIFF".data(using: .ascii)!)
        d.append(uint32: 36 + dataBytes)
        d.append("WAVE".data(using: .ascii)!)
        // fmt chunk
        d.append("fmt ".data(using: .ascii)!)
        d.append(uint32: 16)            // chunk size
        d.append(uint16: 1)             // PCM
        d.append(uint16: 1)             // channels
        d.append(uint32: sampleRate)
        d.append(uint32: sampleRate * 2)
        d.append(uint16: 2)             // block align
        d.append(uint16: 16)            // bits per sample
        // data chunk
        d.append("data".data(using: .ascii)!)
        d.append(uint32: dataBytes)
        d.append(Data(count: Int(dataBytes)))
        return d
    }
}

private extension Data {
    mutating func append(uint16 v: UInt16) {
        var v = v.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
    mutating func append(uint32 v: UInt32) {
        var v = v.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
}
#endif
