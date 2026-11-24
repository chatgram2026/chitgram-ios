import Foundation
import ChitgramCore

// Novagram Ghost Mode — single source of truth for "do not signal read/seen/online" gate.
//
// Read at runtime (no caching) so toggling Ghost mode in Settings or via the navbar
// shortcut takes effect immediately for the next outgoing acknowledgement.
//
// This file is the ONLY new file we add to TelegramCore for Novagram. Keeping the
// gate in TelegramCore is unavoidable because the network requests it gates live
// here, and TelegramCore is a base module that cannot import the Novagram module
// (which sits above it in the dependency graph).
//
// All consumer sites use a 1-line guard:
//
//     if isNovagramGhostModeActive { return .complete() }
//
// Storage key is shared with the rest of the Novagram settings (UserDefaults suite
// "pro_messager", boolean key "is_ghost_mode_active"). The suite name is legacy and
// kept for storage continuity with existing user installs.
/// Novagram's ghost switch (the chat list's ghost button): hides every signal.
@inline(__always)
internal var isNovagramGhostMasterOn: Bool {
    return UserDefaults(suiteName: "pro_messager")?.bool(forKey: "is_ghost_mode_active") ?? false
}

/// Read receipts are held back. Chitgram: also by Android's own switch ("Hide read receipts", `ghost_hide_read`),
/// which syncs with Android through the account's cloud copy.
@inline(__always)
internal var isNovagramGhostModeActive: Bool {
    return isNovagramGhostMasterOn || ChitgramPreferences.shared.bool(.ghostHideRead)
}

/// Chitgram: the account stays offline (Android "Hide online status", `ghost_hide_online`).
internal var isNovagramGhostHidingOnline: Bool {
    return isNovagramGhostMasterOn || ChitgramPreferences.shared.bool(.ghostHideOnline)
}

/// Chitgram: stories are watched without telling the author (Android "View stories anonymously", `ghost_story`).
internal var isNovagramGhostHidingStoryViews: Bool {
    return isNovagramGhostMasterOn || ChitgramPreferences.shared.bool(.ghostStory)
}

/// Chitgram: whether this chat action is held back. Android's groups (`GhostVariable.blocksAction`): typing,
/// recording and picking a sticker follow "Hide typing"; uploads follow "Hide sending progress"; the rest only the
/// master switch.
internal func isNovagramGhostHiding(_ activity: PeerInputActivity) -> Bool {
    if isNovagramGhostMasterOn {
        return true
    }
    let preferences = ChitgramPreferences.shared
    switch activity {
    case .typingText, .recordingVoice, .recordingInstantVideo, .choosingSticker:
        return preferences.bool(.ghostHideTyping)
    case .uploadingFile, .uploadingPhoto, .uploadingVideo, .uploadingInstantVideo:
        return preferences.bool(.ghostHideUpload)
    case .playingGame, .speakingInGroupCall, .interactingWithEmoji, .seeingEmojiInteraction:
        return false
    }
}
