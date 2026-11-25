import Foundation

/// Android `TimeWithSeconds`: clock times as 12:01:45 instead of 12:01 (message times, the chat list, dates with a
/// time). Device-only, off by default.
public enum ChitgramClock {
    public static var showsSeconds: Bool {
        return ChitgramPreferences.shared.bool(.timeWithSeconds)
    }
}

/// Android `AvatarOpensProfile`: a tap on a chat's round avatar in the chat list opens the profile instead of the
/// chat; a story ring or a community keeps its own tap. Device-only, off by default.
public enum ChitgramChatListOptions {
    public static var avatarOpensProfile: Bool {
        return ChitgramPreferences.shared.bool(.avatarOpensProfile)
    }
}
