import Foundation
import ChitgramCore

/// The voice changer's state (Android `VoiceChanger`): a choice for voice messages and one for calls, each an effect
/// with its own settings. Kept on this device only, as on Android.
public enum ChitgramVoiceChanger {
    /// Voice messages.
    public static let messages = ChitgramVoiceChoice(prefix: "", allowSpeed: true)
    /// Calls; a tape speed can't change a live voice, so it is never one.
    public static let calls = ChitgramVoiceChoice(prefix: "call_", allowSpeed: false)

    public static func of(forCall: Bool) -> ChitgramVoiceChoice {
        return forCall ? self.calls : self.messages
    }
}

/// One choice of effect and its settings (Android `Choice`). The recorder reads it once per recording and a call's
/// audio every 10 ms, so the resolved preset is cached and `revision` tells a call that the choice changed.
public final class ChitgramVoiceChoice {
    private let prefix: String
    private let allowSpeed: Bool
    private let lock = NSLock()
    private var resolved: ChitgramVoicePreset?
    private var revisionValue = 0

    init(prefix: String, allowSpeed: Bool) {
        self.prefix = prefix
        self.allowSpeed = allowSpeed
    }

    private var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private func key(_ name: String) -> String {
        return "voice_changer_" + self.prefix + name
    }

    /// The chosen preset with its settings applied; an id no preset has any more reads as off.
    public var preset: ChitgramVoicePreset {
        return self.presetAndRevision().preset
    }

    /// The preset and the number of changes so far, read together.
    public func presetAndRevision() -> (preset: ChitgramVoicePreset, revision: Int) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if let resolved = self.resolved {
            return (resolved, self.revisionValue)
        }
        let value = self.resolve()
        self.resolved = value
        return (value, self.revisionValue)
    }

    public var presetId: Int {
        get {
            return self.preset.id
        }
        set {
            self.defaults.set(newValue, forKey: self.key("preset"))
            self.changed()
        }
    }

    public var params: ChitgramVoiceParams {
        get {
            let defaults = self.defaults
            let fallback = ChitgramVoiceParams.defaultParams
            func read(_ name: String, _ value: Int, _ lower: Int, _ upper: Int) -> Int {
                let stored = defaults.object(forKey: self.key(name)) as? Int ?? value
                return min(max(stored, lower), upper)
            }
            return ChitgramVoiceParams(
                tone: read("tone", fallback.tone, ChitgramVoiceParams.toneMin, ChitgramVoiceParams.toneMax),
                echoDelay: read("echo_delay", fallback.echoDelay, ChitgramVoiceParams.stepMin, ChitgramVoiceParams.stepMax),
                echoVolume: read("echo_volume", fallback.echoVolume, ChitgramVoiceParams.stepMin, ChitgramVoiceParams.stepMax),
                noiseVolume: read("noise_volume", fallback.noiseVolume, ChitgramVoiceParams.stepMin, ChitgramVoiceParams.stepMax)
            )
        }
        set {
            let defaults = self.defaults
            defaults.set(newValue.tone, forKey: self.key("tone"))
            defaults.set(newValue.echoDelay, forKey: self.key("echo_delay"))
            defaults.set(newValue.echoVolume, forKey: self.key("echo_volume"))
            defaults.set(newValue.noiseVolume, forKey: self.key("noise_volume"))
            self.changed()
        }
    }

    public var isOn: Bool {
        return self.preset.id != ChitgramVoicePreset.off
    }

    /// The effect's name as the settings row shows it: a speed by its own name, none as "Off".
    public func title() -> String {
        return ChitgramStrings.get(self.preset.titleId)
    }

    /// A new effect for one recording, or nil when this choice is off.
    public func newEffect(sampleRate: Int) -> ChitgramVoiceEffect? {
        let preset = self.preset
        return preset.id == ChitgramVoicePreset.off ? nil : ChitgramVoiceEffect(preset: preset, sampleRate: sampleRate)
    }

    private func changed() {
        self.lock.lock()
        self.resolved = self.resolve()
        self.revisionValue += 1
        self.lock.unlock()
        // Open screens (the Chitgram settings rows, the picker) show the new choice.
        ChitgramPreferences.shared.notifyChanged()
    }

    private func resolve() -> ChitgramVoicePreset {
        let id = self.defaults.object(forKey: self.key("preset")) as? Int ?? ChitgramVoicePreset.off
        let base = (!self.allowSpeed && ChitgramVoicePreset.isSpeed(id)) ? ChitgramVoicePreset.byId(ChitgramVoicePreset.off) : ChitgramVoicePreset.byId(id)
        return base.with(self.params)
    }
}

/// The voice changer in calls (Android `CallVoiceChanger`): changes the microphone's buffers in place on the audio
/// thread, before WebRTC takes them. WebRTC needs every buffer back at its own size, but an effect hands back what it
/// has (the pitch shifter holds some back), so the voice passes through a small queue: it starts once one buffer more
/// than needed is in it, and from then on a buffer out matches a buffer in. A choice made during the call applies at
/// once. Used from the audio thread only.
public final class ChitgramCallVoiceChanger {
    private var effect: ChitgramVoiceEffect?
    private var effectRevision = -1
    private var effectSampleRate = 0
    private var queue: [Int16] = []
    private var started = false

    public init() {
    }

    /// Changes `frames` samples of mono PCM in place.
    public func process(_ pcm: UnsafeMutablePointer<Int16>, frames: Int, channels: Int, sampleRate: UInt32) {
        if channels != 1 || frames <= 0 {
            return
        }
        let (preset, revision) = ChitgramVoiceChanger.calls.presetAndRevision()
        if revision != self.effectRevision || Int(sampleRate) != self.effectSampleRate {
            self.effectRevision = revision
            self.effectSampleRate = Int(sampleRate)
            self.effect = preset.id == ChitgramVoicePreset.off ? nil : ChitgramVoiceEffect(preset: preset, sampleRate: Int(sampleRate))
            self.queue.removeAll(keepingCapacity: true)
            self.started = false
        }
        guard let effect = self.effect else {
            return
        }
        let input = Array(UnsafeBufferPointer(start: pcm, count: frames))
        self.queue.append(contentsOf: effect.process(input))

        // Silence until the queue holds a buffer to spare; then a buffer out for every buffer in. Should the effect
        // fall behind, the gap is silent; should it run ahead, the oldest samples go rather than the delay growing.
        if !self.started && self.queue.count >= frames * 2 {
            self.started = true
        }
        if self.queue.count > frames * 6 {
            self.queue.removeFirst(self.queue.count - frames * 2)
        }
        if !self.started {
            for i in 0 ..< frames {
                pcm[i] = 0
            }
            return
        }
        let take = min(frames, self.queue.count)
        for i in 0 ..< take {
            pcm[i] = self.queue[i]
        }
        if take < frames {
            for i in take ..< frames {
                pcm[i] = 0
            }
        }
        self.queue.removeFirst(take)
    }
}
