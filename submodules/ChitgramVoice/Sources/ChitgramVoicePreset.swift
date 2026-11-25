import Foundation
import ChitgramCore

/// One preset of the voice changer (Android `VoicePreset`, the same 15 as Graph Messenger's, in its order): a pitch
/// shift or a tape-speed change, plus a few simple stages after it. Modulation, Echo and Noise have settings
/// (`with`); every other preset always sounds the same. `gain` brings each preset back to about the loudness of the
/// voice it was given.
public struct ChitgramVoicePreset: Equatable {
    /// Stored in the settings, so never renumbered.
    public let id: Int
    /// The id of the name in Android's strings table.
    public let titleId: Int
    /// Shown before the name in the picker.
    public let emoji: String
    var semitones: Float = 0.0
    /// Where the formants end up, in semitones apart from the pitch; nil leaves them moving with the pitch.
    var formant: Float? = nil
    /// Tape speed: above 1 faster and thinner, below 1 slower and thicker; the message's length changes.
    var rate: Float = 1.0
    /// Robot: the voice rebuilt as a monotone buzz at this many hertz.
    var robotHz: Float = 0.0
    /// Ring modulation: the voice times a sine of `ringHz`; `ringMix` 1 is fully modulated.
    var ringHz: Float = 0.0
    var ringMix: Float = 0.0
    /// Feedback echo; every repeat a little duller.
    var echoMs: Float = 0.0
    var echoFeedback: Float = 0.0
    var echoMix: Float = 0.0
    /// Freeverb: wet level, room size 0...1, high-frequency loss 0...1.
    var reverbMix: Float = 0.0
    var reverbRoom: Float = 0.5
    var reverbDamp: Float = 0.5
    var reverbPreDelayMs: Float = 0.0
    /// Soft clipping, 0 is none.
    var drive: Float = 0.0
    /// Hoarseness: the voice turned to breath mixed in, and a rough flutter.
    var whisper: Float = 0.0
    var roughness: Float = 0.0
    /// Constant soft background noise.
    var noise: Float = 0.0
    /// Output level.
    var gain: Float = 1.0

    init(id: Int, titleId: Int, emoji: String) {
        self.id = id
        self.titleId = titleId
        self.emoji = emoji
    }

    /// A tape speed, a tone change and its settings are what make a recording's length differ from the microphone's.
    public var changesLength: Bool {
        return self.rate != 1.0
    }

    /// This preset with `params` applied, for the three presets that have settings; any other is returned as it is.
    public func with(_ params: ChitgramVoiceParams) -> ChitgramVoicePreset {
        var copy = self
        switch self.id {
        case ChitgramVoicePreset.modulation:
            // A pitch the user picks; the formants go half as far. At 0 the voice passes as it is.
            if params.tone == 0 {
                copy.semitones = 0.0
                copy.formant = nil
            } else {
                copy.semitones = Float(params.tone)
                copy.formant = Float(params.tone) / 2.0
            }
        case ChitgramVoicePreset.echo:
            let volume = Float(params.echoVolume) / 10.0
            let mix = volume * 0.8
            copy.echoMs = Float(params.echoDelay) * 100.0
            copy.echoMix = mix
            copy.echoFeedback = 0.25 + 0.3 * volume
            copy.gain = 1.0 / (1.0 + 0.35 * mix)
        case ChitgramVoicePreset.noise:
            copy.noise = 0.03 * Float(params.noiseVolume) / 10.0
        default:
            break
        }
        return copy
    }

    public static let off = 0
    public static let modulation = 14
    public static let echo = 10
    public static let noise = 15
    /// The picker's "Record speed" row, which stands for the four speeds.
    public static let speedRow = -1

    private static let speedEmoji = "\u{23E9}"

    private static func make(_ id: Int, _ titleId: Int, _ emoji: String, _ configure: (inout ChitgramVoicePreset) -> Void) -> ChitgramVoicePreset {
        var preset = ChitgramVoicePreset(id: id, titleId: titleId, emoji: emoji)
        configure(&preset)
        return preset
    }

    /// The four tape speeds, thickest first.
    public static let speeds: [ChitgramVoicePreset] = [
        ChitgramVoicePreset.make(16, 827, ChitgramVoicePreset.speedEmoji, { $0.rate = 0.7 }),
        ChitgramVoicePreset.make(17, 828, ChitgramVoicePreset.speedEmoji, { $0.rate = 0.85 }),
        ChitgramVoicePreset.make(18, 829, ChitgramVoicePreset.speedEmoji, { $0.rate = 1.25 }),
        ChitgramVoicePreset.make(19, 830, ChitgramVoicePreset.speedEmoji, { $0.rate = 1.5 })
    ]

    /// The picker's rows in Graph's order; `speedRow` stands for `speeds`.
    public static let rows: [ChitgramVoicePreset] = [
        ChitgramVoicePreset.make(ChitgramVoicePreset.off, 811, "\u{274C}", { _ in }),
        ChitgramVoicePreset.make(ChitgramVoicePreset.speedRow, 822, ChitgramVoicePreset.speedEmoji, { _ in }),
        // robotic
        ChitgramVoicePreset.make(8, 819, "\u{1F916}", { $0.robotHz = 120.0; $0.gain = 1.15 }),
        // alien
        ChitgramVoicePreset.make(9, 820, "\u{1F47D}", { $0.semitones = 4.0; $0.ringHz = 140.0; $0.ringMix = 0.6; $0.gain = 1.6 }),
        // hoarseness
        ChitgramVoicePreset.make(13, 824, "\u{1F5E3}\u{FE0F}", { $0.whisper = 0.5; $0.roughness = 0.15; $0.drive = 1.3 }),
        // modulation: a pitch of the user's choice
        ChitgramVoicePreset.make(ChitgramVoicePreset.modulation, 825, "\u{1F39B}\u{FE0F}", { _ in }).with(ChitgramVoiceParams.defaultParams),
        // child
        ChitgramVoicePreset.make(1, 812, "\u{1F9D2}", { $0.semitones = 12.0; $0.formant = 5.5; $0.gain = 1.1 }),
        // mouse
        ChitgramVoicePreset.make(7, 818, "\u{1F401}", { $0.semitones = 14.0 }),
        // man
        ChitgramVoicePreset.make(3, 814, "\u{1F468}\u{200D}\u{1F9B0}", { $0.semitones = -6.0; $0.formant = -3.0 }),
        // woman
        ChitgramVoicePreset.make(2, 813, "\u{1F469}\u{200D}\u{1F9B0}", { $0.semitones = 9.0; $0.formant = 3.5; $0.gain = 1.1 }),
        // monster
        ChitgramVoicePreset.make(6, 817, "\u{1F47A}", { $0.semitones = -8.0; $0.formant = -5.0; $0.drive = 2.5; $0.ringHz = 30.0; $0.ringMix = 0.25; $0.gain = 0.54 }),
        // echo
        ChitgramVoicePreset.make(ChitgramVoicePreset.echo, 821, "\u{1F399}\u{FE0F}", { _ in }).with(ChitgramVoiceParams.defaultParams),
        // noise
        ChitgramVoicePreset.make(ChitgramVoicePreset.noise, 826, "\u{1F4A5}", { _ in }).with(ChitgramVoiceParams.defaultParams),
        // helium: mostly the formants go up, the pitch only a little
        ChitgramVoicePreset.make(4, 815, "\u{1F388}", { $0.semitones = 3.0; $0.formant = 9.0; $0.gain = 0.95 }),
        // hexafluoride: the other way, a heavy gas
        ChitgramVoicePreset.make(5, 816, "\u{1F388}", { $0.semitones = -3.0; $0.formant = -7.0; $0.gain = 1.08 }),
        // cave
        ChitgramVoicePreset.make(12, 823, "\u{1F573}\u{FE0F}", { $0.reverbMix = 0.3; $0.reverbRoom = 0.7; $0.reverbDamp = 0.3; $0.reverbPreDelayMs = 35.0 })
    ]

    public static func byId(_ id: Int) -> ChitgramVoicePreset {
        if let preset = self.rows.first(where: { $0.id == id && $0.id != speedRow }) {
            return preset
        }
        if let preset = self.speeds.first(where: { $0.id == id }) {
            return preset
        }
        return self.rows[0]
    }

    public static func isSpeed(_ id: Int) -> Bool {
        return self.speeds.contains(where: { $0.id == id })
    }

    public static func hasSettings(_ id: Int) -> Bool {
        return id == modulation || id == echo || id == noise
    }

    /// A preset's settings as its row shows them: "+5", "70%, 0.5 sec", "70%".
    public static func settingsText(_ id: Int, params: ChitgramVoiceParams) -> String? {
        switch id {
        case modulation:
            return toneText(params.tone)
        case echo:
            return percentText(params.echoVolume) + ", " + secondsText(params.echoDelay)
        case noise:
            return percentText(params.noiseVolume)
        default:
            return nil
        }
    }

    public static func toneText(_ tone: Int) -> String {
        return tone > 0 ? "+\(tone)" : "\(tone)"
    }

    public static func percentText(_ step: Int) -> String {
        return "\(step * 10)%"
    }

    public static func secondsText(_ step: Int) -> String {
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(step) / 10.0) + " " + ChitgramStrings.get(838)
    }
}

/// What the user sets for Modulation, Echo and Noise, in Graph's steps: the pitch in semitones, the echo's delay in
/// tenths of a second and its volume in tenths, the noise's volume in tenths.
public struct ChitgramVoiceParams: Equatable {
    public var tone: Int
    public var echoDelay: Int
    public var echoVolume: Int
    public var noiseVolume: Int

    public init(tone: Int, echoDelay: Int, echoVolume: Int, noiseVolume: Int) {
        self.tone = tone
        self.echoDelay = echoDelay
        self.echoVolume = echoVolume
        self.noiseVolume = noiseVolume
    }

    public static let toneMin = -12
    public static let toneMax = 12
    public static let stepMin = 1
    public static let stepMax = 10

    /// Graph's defaults: +5 semitones; an echo at 70 % after 0.5 s; noise at 70 %.
    public static let defaultParams = ChitgramVoiceParams(tone: 5, echoDelay: 5, echoVolume: 7, noiseVolume: 7)
}
