import AVFoundation

enum WaveformExtractor {
    /// Extract normalized amplitude samples from an audio file.
    /// Returns an array of floats (0...1) representing the waveform.
    /// Reads in small chunks to keep memory usage low even for multi-hour recordings.
    static func extract(from url: URL, sampleCount: Int = 200) async -> [Float] {
        let cacheURL = url.deletingLastPathComponent().appendingPathComponent("waveform.json")

        // Try loading from cache first
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([Float].self, from: data),
           cached.count == sampleCount {
            return cached
        }

        let samples = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let samples = Self.readSamples(from: url, count: sampleCount)
                continuation.resume(returning: samples)
            }
        }

        // Save to cache
        if !samples.isEmpty, let data = try? JSONEncoder().encode(samples) {
            try? data.write(to: cacheURL, options: .atomic)
        }

        return samples
    }

    private static func readSamples(from url: URL, count: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }

        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return [] }

        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return [] }

        let framesPerSample = max(totalFrames / count, 1)

        // Read in chunks of ~1 second to keep memory under ~400KB
        let chunkSize = min(Int(format.sampleRate), totalFrames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkSize)) else {
            return []
        }

        var samples: [Float] = []
        samples.reserveCapacity(count)

        var currentFrame = 0
        var sampleIndex = 0
        var accumulator: Float = 0
        var frameCount = 0

        while currentFrame < totalFrames, sampleIndex < count {
            let framesToRead = min(chunkSize, totalFrames - currentFrame)
            buffer.frameLength = 0

            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))
            } catch {
                break
            }

            guard let floatData = buffer.floatChannelData else { break }
            let framesRead = Int(buffer.frameLength)

            for i in 0..<framesRead {
                var channelSum: Float = 0
                for ch in 0..<channelCount {
                    channelSum += abs(floatData[ch][i])
                }
                accumulator += channelSum / Float(channelCount)
                frameCount += 1

                if frameCount >= framesPerSample {
                    samples.append(accumulator / Float(frameCount))
                    accumulator = 0
                    frameCount = 0
                    sampleIndex += 1
                    if sampleIndex >= count { break }
                }
            }

            currentFrame += framesRead
        }

        // Flush remaining
        if frameCount > 0, sampleIndex < count {
            samples.append(accumulator / Float(frameCount))
        }

        // Normalize to 0...1
        let peak = samples.max() ?? 1
        guard peak > 0 else { return samples }
        return samples.map { $0 / peak }
    }
}
