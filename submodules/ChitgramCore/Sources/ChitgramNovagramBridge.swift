import Foundation

/// Android's settings copy in Saved Messages (`ChitgramCloud`) carries Android's keys, but on this base several of
/// those features are Novagram's, which keep their switches under their own keys in the `pro_messager` suite. This
/// keeps each pair equal both ways: a change made on Android reaches the Novagram feature here, and a change made in
/// Novagram's settings reaches the copy, and so Android.
///
/// Each pair remembers the value both sides last agreed on, so whichever side moved away from it holds the change,
/// whatever order the notifications come in.
public enum ChitgramNovagramBridge {
    private enum Kind {
        /// A switch; `inverted` when Novagram stores the opposite (Novagram "show stories", Android "hide stories").
        case bool(novagramDefault: Bool, inverted: Bool)
        /// A number; Android's range ends at `androidMax`.
        case int(novagramDefault: Int, androidMax: Int)
    }

    private struct Pair {
        let key: ChitgramPreferences.Key
        let novagramKey: String
        let kind: Kind
    }

    private static let pairs: [Pair] = [
        // Ghost mode, and its button on the chat list.
        Pair(key: .ghost, novagramKey: "is_ghost_mode_active", kind: .bool(novagramDefault: false, inverted: false)),
        Pair(key: .ghostButton, novagramKey: "show_ghost_mode_button", kind: .bool(novagramDefault: false, inverted: false)),
        // Stories: the tray (Novagram shows it, Android hides it) and saving stories.
        Pair(key: .hideStory, novagramKey: "show_stories", kind: .bool(novagramDefault: true, inverted: true)),
        Pair(key: .storyDownload, novagramKey: "fenix_story_unlock_enabled", kind: .bool(novagramDefault: false, inverted: false)),
        // Auto-accepting join requests.
        Pair(key: .autoAcceptJoin, novagramKey: "fenix_autoaccept_global", kind: .bool(novagramDefault: false, inverted: false)),
        // The unread message reminder and its delay in minutes (Android allows 1 to 59).
        Pair(key: .reminderEnabled, novagramKey: "unread_reminder_enabled", kind: .bool(novagramDefault: false, inverted: false)),
        Pair(key: .reminderDelayMin, novagramKey: "unread_reminder_minutes", kind: .int(novagramDefault: 5, androidMax: 59)),
        // Hiding the folder tabs.
        Pair(key: .hideTabs, novagramKey: "hide_folders", kind: .bool(novagramDefault: false, inverted: false))
    ]

    private static let agreedKey = "chitgram_novagram_bridge"
    private static var started = false
    private static var scheduled = false
    private static var observers: [NSObjectProtocol] = []

    /// Once at launch, after the stores are configured: brings the pairs into step and keeps them so.
    public static func start() {
        if self.started {
            return
        }
        self.started = true
        self.observers.append(NotificationCenter.default.addObserver(forName: ChitgramPreferences.didChangeNotification, object: nil, queue: nil, using: { _ in
            self.schedule()
        }))
        self.observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil, using: { _ in
            self.schedule()
        }))
        self.reconcile()
    }

    /// Many changes in a row become one pass, on the main queue.
    private static func schedule() {
        let run = {
            if self.scheduled {
                return
            }
            self.scheduled = true
            DispatchQueue.main.async {
                self.scheduled = false
                self.reconcile()
            }
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    private static func novagramValue(_ pair: Pair, _ novagram: UserDefaults) -> Int {
        switch pair.kind {
        case let .bool(novagramDefault, inverted):
            let value = (novagram.object(forKey: pair.novagramKey) as? Bool) ?? novagramDefault
            return value != inverted ? 1 : 0
        case let .int(novagramDefault, androidMax):
            let value = (novagram.object(forKey: pair.novagramKey) as? Int) ?? novagramDefault
            return min(max(value, 1), androidMax)
        }
    }

    private static func chitgramValue(_ pair: Pair) -> Int {
        switch pair.kind {
        case .bool:
            return ChitgramPreferences.shared.bool(pair.key) ? 1 : 0
        case let .int(_, androidMax):
            return min(max(ChitgramPreferences.shared.int(pair.key), 1), androidMax)
        }
    }

    private static func setChitgram(_ pair: Pair, _ value: Int) {
        switch pair.kind {
        case .bool:
            ChitgramPreferences.shared.set(value != 0, for: pair.key)
        case .int:
            ChitgramPreferences.shared.set(value, for: pair.key)
        }
    }

    private static func setNovagram(_ pair: Pair, _ value: Int, _ novagram: UserDefaults) {
        switch pair.kind {
        case let .bool(_, inverted):
            novagram.set((value != 0) != inverted, forKey: pair.novagramKey)
        case .int:
            novagram.set(value, forKey: pair.novagramKey)
        }
    }

    private static func reconcile() {
        guard let novagram = UserDefaults(suiteName: "pro_messager") else {
            return
        }
        let store = ChitgramPreferences.shared.userDefaults
        var agreed = (store.dictionary(forKey: self.agreedKey) as? [String: Int]) ?? [:]
        var agreedChanged = false
        var novagramChanged = false
        for pair in self.pairs {
            let here = self.novagramValue(pair, novagram)
            let shared = self.chitgramValue(pair)
            let last = agreed[pair.key.rawValue]
            let value: Int
            if here == shared {
                value = here
            } else if let last, here != last {
                // Changed in Novagram's settings on this phone: share it.
                self.setChitgram(pair, here)
                value = here
            } else if last != nil || ChitgramPreferences.shared.changeTime(pair.key) != nil {
                // Changed on another phone (the copy) or in Chitgram's own settings: the Novagram feature follows.
                self.setNovagram(pair, shared, novagram)
                novagramChanged = true
                value = shared
            } else {
                // First run, with a Novagram setting changed before it was shared: share it.
                self.setChitgram(pair, here)
                value = here
            }
            if last != value {
                agreed[pair.key.rawValue] = value
                agreedChanged = true
            }
        }
        if agreedChanged {
            store.set(agreed, forKey: self.agreedKey)
        }
        if novagramChanged {
            // The chat list reads these again (folders, stories, the ghost button).
            NotificationCenter.default.post(name: NSNotification.Name("NovagramSettingsChanged"), object: nil)
        }
    }
}
