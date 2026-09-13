// Usage: swift GenerateVideoFixture.swift /absolute/path/stream-test.mp4
// Creates a synthetic 32-second H.264 movie for simulator playback/seek tests.
import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: output)
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let width = 640, height = 360, fps: Int32 = 24
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000, AVVideoMaxKeyFrameIntervalKey: 24]
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
])
writer.add(input)
writer.shouldOptimizeForNetworkUse = true
writer.startWriting(); writer.startSession(atSourceTime: .zero)
for frame in 0..<(32 * Int(fps)) {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var value: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &value)
    let buffer = value!
    CVPixelBufferLockBaseAddress(buffer, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    for row in 0..<18 {
        for column in 0..<32 {
            let seed = UInt32((frame * 131 + row * 79 + column * 17) % 256)
            context.setFillColor(CGColor(red: CGFloat(seed) / 255, green: CGFloat((seed * 7 + 33) % 256) / 255, blue: CGFloat((seed * 3 + 128) % 256) / 255, alpha: 1))
            context.fill(CGRect(x: column * 20, y: row * 20, width: 20, height: 20))
        }
    }
    context.setFillColor(CGColor(gray: 0.05, alpha: 1))
    context.fill(CGRect(x: 0, y: 135, width: width, height: 90))
    context.setFillColor(CGColor(red: 0.2, green: 0.75, blue: 0.55, alpha: 1))
    context.fill(CGRect(x: 20, y: 160, width: max(2, (width - 40) * frame / (32 * Int(fps))), height: 40))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    if !adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) { throw writer.error! }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
if writer.status != .completed { throw writer.error! }
print("Synthetic video ready:", output.path)
print("Bytes:", (try FileManager.default.attributesOfItem(atPath: output.path)[.size])!)
