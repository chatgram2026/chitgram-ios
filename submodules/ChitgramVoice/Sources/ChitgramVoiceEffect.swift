import Foundation

/// The next xorshift state; as a signed 32-bit value over 2^31 it is white noise in -1...1.
private func chitgramXorshift(_ seed: UInt32) -> UInt32 {
    var s = seed
    s ^= s << 13
    s ^= s >> 17
    s ^= s << 5
    return s
}

private func chitgramNoiseValue(_ state: UInt32) -> Float {
    return Float(Int32(bitPattern: state)) / 2147483648.0
}

/// Applies a preset to 16-bit mono PCM, chunk by chunk, as the voice is recorded (Android `VoiceEffect`). `process`
/// may return more or fewer samples than it was given, since the pitch shifter holds some back; `drain` returns what
/// is still held once the recording stops, with an echo or reverb dying away. One instance per recording, used from
/// one thread.
public final class ChitgramVoiceEffect {
    private static let warpHeadroom: Float = 0.5

    public let preset: ChitgramVoicePreset
    private let sampleRate: Int
    // Sonic moves the formants along with the pitch, so the warp moves them only by what is left over.
    private let warp: ChitgramFormantWarp?
    // The warp can raise peaks; it runs at half level and the stages bring the level back.
    private let inputScale: Float
    // What the warp gives for its first `size` samples is the silence before the voice reached it.
    private var warpLagLeft: Int
    // Pitch keeps the length; tape speed resamples, so the same samples play faster or slower.
    private let sonic: ChitgramSonic?
    private let ringStep: Double
    private var ringPhase: Double = 0.0
    private var echo: [Float]
    private var echoPos = 0
    private var echoDamp: Float = 0.0
    private let reverb: ChitgramFreeverb?
    private let spectral: ChitgramSpectral?
    /// What `drain` adds after the voice: the spectral stage's lag, then a second for an echo or a reverb to fade.
    private let spectralLag: Int
    private let fadeLength: Int
    private var roughPhase: Double = 0.0
    private var noiseLow: Float = 0.0
    private var noiseSeed: UInt32 = 0x2545F491

    public init(preset: ChitgramVoicePreset, sampleRate: Int) {
        self.preset = preset
        self.sampleRate = sampleRate
        var warp: ChitgramFormantWarp?
        if let formant = preset.formant {
            warp = ChitgramFormantWarp(factor: powf(2.0, (formant - preset.semitones) / 12.0), sampleRate: sampleRate)
        }
        self.warp = warp
        self.inputScale = warp != nil ? 1.0 / ChitgramVoiceEffect.warpHeadroom : 1.0
        self.warpLagLeft = warp?.size ?? 0
        if preset.semitones != 0.0 || preset.rate != 1.0 {
            self.sonic = ChitgramSonic(inputSampleRateHz: sampleRate, speed: 1.0, pitch: powf(2.0, preset.semitones / 12.0), outputSampleRateHz: Int((Float(sampleRate) / preset.rate).rounded()))
        } else {
            self.sonic = nil
        }
        self.ringStep = 2.0 * Double.pi * Double(preset.ringHz) / Double(sampleRate)
        var echo: [Float] = []
        if preset.echoMs > 0.0 {
            echo = [Float](repeating: 0.0, count: max(1, Int(Float(sampleRate) * preset.echoMs / 1000.0)))
        }
        self.echo = echo
        let reverb: ChitgramFreeverb? = preset.reverbMix > 0.0 ? ChitgramFreeverb(sampleRate: sampleRate, preset: preset) : nil
        self.reverb = reverb
        var spectral: ChitgramSpectral?
        if preset.robotHz > 0.0 {
            spectral = ChitgramSpectral(robot: true, size: 1024, hop: max(1, Int((Float(sampleRate) / preset.robotHz).rounded())))
        } else if preset.whisper > 0.0 {
            spectral = ChitgramSpectral(robot: false, size: 512, hop: 128)
        }
        self.spectral = spectral
        self.spectralLag = spectral?.size ?? 0
        self.fadeLength = (!echo.isEmpty || reverb != nil) ? sampleRate : 0
    }

    /// The samples' changed voice.
    public func process(_ input: [Int16]) -> [Int16] {
        let source = self.warp != nil ? self.warped(input) : input
        var pitched: [Int16]
        if let sonic = self.sonic {
            sonic.queueInput(source)
            pitched = sonic.takeOutput()
        } else {
            pitched = source
        }
        self.applyStages(&pitched)
        return pitched
    }

    /// What the effect still holds once the recording stops; the echo or reverb part fades to nothing.
    public func drain() -> [Int16] {
        // Silence through the warp first: it still holds the last of the voice.
        var warpRest: [Int16] = []
        if let warp = self.warp {
            warpRest = self.warped([Int16](repeating: 0, count: warp.size))
        }
        var rest: [Int16]
        if let sonic = self.sonic {
            sonic.queueInput(warpRest)
            sonic.queueEndOfStream()
            rest = sonic.takeOutput()
        } else {
            rest = warpRest
        }
        let restCount = rest.count
        rest.append(contentsOf: [Int16](repeating: 0, count: self.spectralLag + self.fadeLength))
        self.applyStages(&rest)
        let fadeStart = restCount + self.spectralLag
        for i in 0 ..< self.fadeLength {
            let faded = Float(rest[fadeStart + i]) * (1.0 - Float(i) / Float(self.fadeLength))
            rest[fadeStart + i] = Int16(truncatingIfNeeded: Int(faded))
        }
        return rest
    }

    private func applyStages(_ samples: inout [Int16]) {
        let preset = self.preset
        for i in 0 ..< samples.count {
            var x = Float(samples[i]) / 32768.0 * self.inputScale

            if let spectral = self.spectral {
                let wet = spectral.process(x)
                x = preset.robotHz > 0.0 ? wet : spectral.dryDelayed * (1.0 - preset.whisper) + wet * preset.whisper
            }
            if preset.ringMix > 0.0 {
                let ring = x * Float(sin(self.ringPhase))
                x = x * (1.0 - preset.ringMix) + ring * preset.ringMix
                self.ringPhase += self.ringStep
                if self.ringPhase > 2.0 * Double.pi {
                    self.ringPhase -= 2.0 * Double.pi
                }
            }
            if preset.roughness > 0.0 {
                // An irregular 30...50 Hz flutter of the loudness, like a strained throat.
                self.roughPhase += 2.0 * Double.pi * (40.0 + 10.0 * Double(self.nextNoise())) / Double(self.sampleRate)
                if self.roughPhase > 2.0 * Double.pi {
                    self.roughPhase -= 2.0 * Double.pi
                }
                x *= 1.0 - preset.roughness * (0.5 + 0.5 * Float(sin(self.roughPhase)))
            }
            if preset.drive > 0.0 {
                x = Float(tanh(Double(x * preset.drive)) / tanh(Double(preset.drive)))
            }
            if !self.echo.isEmpty {
                // A one-pole low-pass in the loop: each repeat loses some treble, like a wall far away.
                let past = self.echo[self.echoPos]
                self.echoDamp += (past - self.echoDamp) * 0.6
                self.echo[self.echoPos] = x + self.echoDamp * preset.echoFeedback
                self.echoPos = (self.echoPos + 1) % self.echo.count
                x += self.echoDamp * preset.echoMix
            }
            if let reverb = self.reverb {
                x = x * (1.0 - preset.reverbMix * 0.5) + reverb.process(x) * preset.reverbMix
            }
            if preset.noise > 0.0 {
                // Softened (low-passed) noise, a hiss rather than a hard white noise.
                self.noiseLow += (self.nextNoise() - self.noiseLow) * 0.35
                x += self.noiseLow * preset.noise * 2.0
            }

            x *= preset.gain
            let limited = ChitgramVoiceEffect.softLimit(x)
            samples[i] = limited.isFinite ? Int16(truncatingIfNeeded: Int(limited * 32767.0)) : 0
        }
    }

    /// Linear up to 0.9, then bends smoothly toward 1, so loud peaks never clip hard.
    private static func softLimit(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.9 {
            return x
        }
        let bent = 0.9 + 0.1 * Float(tanh(Double((a - 0.9) / 0.1)))
        return x < 0.0 ? -bent : bent
    }

    private func nextNoise() -> Float {
        self.noiseSeed = chitgramXorshift(self.noiseSeed)
        return chitgramNoiseValue(self.noiseSeed)
    }

    /// The samples through the warp, without its lag at the start.
    private func warped(_ input: [Int16]) -> [Int16] {
        guard let warp = self.warp else {
            return input
        }
        let count = input.count
        let skip = min(self.warpLagLeft, count)
        var out = [Int16](repeating: 0, count: count - skip)
        for i in 0 ..< count {
            let y = warp.process(Float(input[i]) / 32768.0) * ChitgramVoiceEffect.warpHeadroom
            if i >= skip {
                let scaled = y * 32767.0
                out[i - skip] = scaled.isFinite ? Int16(max(-32768.0, min(32767.0, scaled))) : 0
            }
        }
        self.warpLagLeft -= skip
        return out
    }
}

/// Moves the formants (the resonances of the throat and mouth) by `factor` along the frequency axis and leaves the
/// pitch where it is (Android `FormantWarp`). In each STFT frame the spectral envelope is the log spectrum smoothed
/// through the cepstrum, and the frame is filtered by the warped envelope over its own. 75 % overlapping Hann windows;
/// the output lags the input by `size` samples.
final class ChitgramFormantWarp {
    /// 1.5 ms: half the pitch period of a 330 Hz voice, so a high voice's harmonics stay out of the envelope.
    private static let lifterSeconds: Float = 0.0015
    private static let lifterTaper = 16
    /// ln(8): at most 18 dB up or down.
    private static let maxLogGain: Float = 2.0794415

    let size: Int
    private let factor: Float
    private let hop: Int
    private let half: Int
    private let lifter: Int
    private let window: [Float]
    private var input: [Float]
    private var output: [Float]
    private var re: [Float]
    private var im: [Float]
    private var cepstrumRe: [Float]
    private var cepstrumIm: [Float]
    private var envelope: [Float]
    private let fft: ChitgramFft
    private var pos = 0
    private var sinceFrame = 0
    // Hann analysis and synthesis at 75 % overlap add up to 1.5.
    private let scale: Float

    init(factor: Float, sampleRate: Int) {
        let size = sampleRate > 32000 ? 2048 : 1024
        self.size = size
        self.factor = factor
        self.hop = size / 4
        self.half = size / 2
        self.lifter = max(8, Int((Float(sampleRate) * ChitgramFormantWarp.lifterSeconds).rounded()))
        self.window = (0 ..< size).map { Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / Double(size))) }
        self.input = [Float](repeating: 0.0, count: size)
        self.output = [Float](repeating: 0.0, count: size)
        self.re = [Float](repeating: 0.0, count: size)
        self.im = [Float](repeating: 0.0, count: size)
        self.cepstrumRe = [Float](repeating: 0.0, count: size)
        self.cepstrumIm = [Float](repeating: 0.0, count: size)
        self.envelope = [Float](repeating: 0.0, count: size / 2 + 1)
        self.fft = ChitgramFft(size: size)
        self.scale = Float(size / 4) / (0.375 * Float(size))
    }

    func process(_ x: Float) -> Float {
        self.input[self.pos] = x
        let y = self.output[self.pos]
        self.output[self.pos] = 0.0
        self.pos = (self.pos + 1) % self.size
        self.sinceFrame += 1
        if self.sinceFrame == self.hop {
            self.sinceFrame = 0
            self.frame()
        }
        return y
    }

    private func frame() {
        let size = self.size
        let half = self.half
        for i in 0 ..< size {
            self.re[i] = self.input[(self.pos + i) % size] * self.window[i]
            self.im[i] = 0.0
        }
        self.fft.transform(&self.re, &self.im, inverse: false)
        // The log magnitude, an even real sequence, through the inverse transform: the cepstrum.
        for k in 0 ... half {
            let level = logf(hypotf(self.re[k], self.im[k]) + 1e-9)
            self.cepstrumRe[k] = level
            self.cepstrumIm[k] = 0.0
            if k >= 1 && k < half {
                self.cepstrumRe[size - k] = level
                self.cepstrumIm[size - k] = 0.0
            }
        }
        self.fft.transform(&self.cepstrumRe, &self.cepstrumIm, inverse: true)
        let taper = ChitgramFormantWarp.lifterTaper
        for n in 0 ..< size {
            let quefrency = n <= half ? n : size - n
            let weight: Float
            if quefrency < self.lifter {
                weight = 1.0
            } else if quefrency < self.lifter + taper {
                weight = Float(0.5 + 0.5 * cos(Double.pi * Double(quefrency - self.lifter) / Double(taper)))
            } else {
                weight = 0.0
            }
            self.cepstrumRe[n] *= weight
            self.cepstrumIm[n] = 0.0
        }
        self.fft.transform(&self.cepstrumRe, &self.cepstrumIm, inverse: false)
        for k in 0 ... half {
            self.envelope[k] = self.cepstrumRe[k]
        }
        let maxLogGain = ChitgramFormantWarp.maxLogGain
        for k in 0 ... half {
            // The envelope `factor` times lower down lands here: above 1 the formants go up.
            let from = Float(k) / self.factor
            let below = Int(from)
            let target: Float
            if below >= half {
                target = self.envelope[half]
            } else {
                target = self.envelope[below] + (self.envelope[below + 1] - self.envelope[below]) * (from - Float(below))
            }
            // Limited, so that a quiet valley or the noise between words isn't blown up.
            let gain = expf(min(max(target - self.envelope[k], -maxLogGain), maxLogGain))
            self.re[k] *= gain
            self.im[k] *= gain
            if k >= 1 && k < half {
                self.re[size - k] = self.re[k]
                self.im[size - k] = -self.im[k]
            }
        }
        self.fft.transform(&self.re, &self.im, inverse: true)
        for i in 0 ..< size {
            self.output[(self.pos + i) % size] += self.re[i] * self.window[i] * self.scale
        }
    }
}

/// Short-time Fourier processing for the effects that rebuild the voice from its spectrum (Android `Spectral`): a
/// robot keeps each frame's spectrum but drops its phases, so every frame becomes one pulse and the voice takes the
/// monotone pitch of the frame rate; a whisper gives the phases random values, turning the voice into breath that keeps
/// its vowels. The output lags the input by `size` samples, and `dryDelayed` is the input with the same lag.
final class ChitgramSpectral {
    let size: Int
    private let robot: Bool
    private let hop: Int
    private let window: [Float]
    private var input: [Float]
    private var output: [Float]
    private var re: [Float]
    private var im: [Float]
    private let fft: ChitgramFft
    private var pos = 0
    private var sinceFrame = 0
    private var seed: UInt32 = 0x6C8E9CF5
    // Keeps the level: overlapping frames add up in phase for the robot's pulses, at random for the whisper.
    private let scale: Float

    private(set) var dryDelayed: Float = 0.0

    init(robot: Bool, size: Int, hop: Int) {
        self.robot = robot
        self.size = size
        self.hop = hop
        self.window = (0 ..< size).map { Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / Double(size))) }
        self.input = [Float](repeating: 0.0, count: size)
        self.output = [Float](repeating: 0.0, count: size)
        self.re = [Float](repeating: 0.0, count: size)
        self.im = [Float](repeating: 0.0, count: size)
        self.fft = ChitgramFft(size: size)
        self.scale = robot ? Float(hop) / (0.375 * Float(size)) : sqrtf(Float(hop) / (0.140625 * Float(size)))
    }

    func process(_ x: Float) -> Float {
        self.dryDelayed = self.input[self.pos]
        self.input[self.pos] = x
        let y = self.output[self.pos]
        self.output[self.pos] = 0.0
        self.pos = (self.pos + 1) % self.size
        self.sinceFrame += 1
        if self.sinceFrame == self.hop {
            self.sinceFrame = 0
            self.frame()
        }
        return y
    }

    /// Analyses the last `size` samples and adds the rebuilt frame to the output, starting with the next sample.
    private func frame() {
        let size = self.size
        for i in 0 ..< size {
            self.re[i] = self.input[(self.pos + i) % size] * self.window[i]
            self.im[i] = 0.0
        }
        self.fft.transform(&self.re, &self.im, inverse: false)
        let half = size / 2
        self.re[0] = 0.0
        self.im[0] = 0.0
        for k in 1 ... half {
            let magnitude = hypotf(self.re[k], self.im[k])
            if self.robot {
                // Zero phase, moved to the middle of the frame (the sign flip of odd bins) where the window is open.
                self.re[k] = k % 2 == 0 ? magnitude : -magnitude
                self.im[k] = 0.0
            } else {
                self.seed = chitgramXorshift(self.seed)
                let angle = Double(chitgramNoiseValue(self.seed)) * Double.pi
                self.re[k] = magnitude * Float(cos(angle))
                self.im[k] = k == half ? 0.0 : magnitude * Float(sin(angle))
            }
            if k < half {
                self.re[size - k] = self.re[k]
                self.im[size - k] = -self.im[k]
            }
        }
        self.fft.transform(&self.re, &self.im, inverse: true)
        for i in 0 ..< size {
            self.output[(self.pos + i) % size] += self.re[i] * self.window[i] * self.scale
        }
    }
}

/// In-place radix-2 complex FFT of a fixed power-of-two size; the inverse is scaled by 1/size.
final class ChitgramFft {
    private let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let reversed: [Int]

    init(size: Int) {
        self.size = size
        self.cosTable = (0 ..< size / 2).map { Float(cos(2.0 * Double.pi * Double($0) / Double(size))) }
        self.sinTable = (0 ..< size / 2).map { Float(sin(2.0 * Double.pi * Double($0) / Double(size))) }
        var reversed = [Int](repeating: 0, count: size)
        var j = 0
        for i in 1 ..< size {
            var bit = size >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            reversed[i] = j
        }
        self.reversed = reversed
    }

    func transform(_ re: inout [Float], _ im: inout [Float], inverse: Bool) {
        let size = self.size
        for i in 0 ..< size {
            let j = self.reversed[i]
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var length = 2
        while length <= size {
            let half = length / 2
            let step = size / length
            var start = 0
            while start < size {
                for k in 0 ..< half {
                    let wr = self.cosTable[k * step]
                    let wi = inverse ? self.sinTable[k * step] : -self.sinTable[k * step]
                    let a = start + k
                    let b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += length
            }
            length <<= 1
        }
        if inverse {
            let s = 1.0 / Float(size)
            for i in 0 ..< size {
                re[i] *= s
                im[i] *= s
            }
        }
    }
}

/// Freeverb (Jezar at Dreampoint, public domain): eight damped feedback combs in parallel, then four allpasses in series,
/// the 44.1 kHz tunings scaled to the sample rate. Mono, wet signal only (Android `Freeverb`).
final class ChitgramFreeverb {
    private var combs: [[Float]]
    private var combPos: [Int]
    private var combStore: [Float]
    private var allpasses: [[Float]]
    private var allpassPos: [Int]
    private let feedback: Float
    private let damp: Float
    private var preDelay: [Float]
    private var preDelayPos = 0
    // A one-pole high-pass at 200 Hz on what goes into the reverb, so low notes don't pile up into a boom.
    private let highPassCoef: Float
    private var highPassOut: Float = 0.0
    private var highPassIn: Float = 0.0

    init(sampleRate: Int, preset: ChitgramVoicePreset) {
        let scale = Float(sampleRate) / 44100.0
        self.combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617].map { [Float](repeating: 0.0, count: max(1, Int(Float($0) * scale))) }
        self.combPos = [Int](repeating: 0, count: 8)
        self.combStore = [Float](repeating: 0.0, count: 8)
        self.allpasses = [556, 441, 341, 225].map { [Float](repeating: 0.0, count: max(1, Int(Float($0) * scale))) }
        self.allpassPos = [Int](repeating: 0, count: 4)
        self.feedback = preset.reverbRoom * 0.28 + 0.7
        self.damp = preset.reverbDamp * 0.4
        if preset.reverbPreDelayMs > 0.0 {
            self.preDelay = [Float](repeating: 0.0, count: max(1, Int(Float(sampleRate) * preset.reverbPreDelayMs / 1000.0)))
        } else {
            self.preDelay = []
        }
        self.highPassCoef = Float(exp(-2.0 * Double.pi * 200.0 / Double(sampleRate)))
    }

    func process(_ dry: Float) -> Float {
        self.highPassOut = self.highPassCoef * (self.highPassOut + dry - self.highPassIn)
        self.highPassIn = dry
        let x = self.highPassOut
        var input = x
        if !self.preDelay.isEmpty {
            let delayed = self.preDelay[self.preDelayPos]
            self.preDelay[self.preDelayPos] = x
            self.preDelayPos = (self.preDelayPos + 1) % self.preDelay.count
            input = delayed
        }
        input *= 0.015 * 2.0
        var out: Float = 0.0
        for c in 0 ..< self.combs.count {
            let pos = self.combPos[c]
            let y = self.combs[c][pos]
            self.combStore[c] = y * (1.0 - self.damp) + self.combStore[c] * self.damp
            self.combs[c][pos] = input + self.combStore[c] * self.feedback
            self.combPos[c] = (pos + 1) % self.combs[c].count
            out += y
        }
        for a in 0 ..< self.allpasses.count {
            let pos = self.allpassPos[a]
            let buffered = self.allpasses[a][pos]
            self.allpasses[a][pos] = out + buffered * 0.5
            self.allpassPos[a] = (pos + 1) % self.allpasses[a].count
            out = buffered - out
        }
        return out * 3.0
    }
}
