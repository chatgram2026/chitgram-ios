import Foundation
import SwiftSignalKit

/// Android's per-account notification switch (`NotificationsController.isAccountNotificationsEnabled`): an account's
/// messages and calls can be silenced on this device alone, with the switch at the end of its row in Settings. Kept
/// under Android's key, `account_notify_<user id>`, in the app group; device-only, as on Android, so it is not synced.
public enum ChitgramAccountNotifications {
    public static let didChangeNotification = Notification.Name("ChitgramAccountNotificationsDidChange")

    private static let keyPrefix = "account_notify_"

    public static func isEnabled(userId: Int64) -> Bool {
        return (ChitgramPreferences.shared.userDefaults.object(forKey: self.keyPrefix + "\(userId)") as? Bool) ?? true
    }

    public static func setEnabled(_ enabled: Bool, userId: Int64) {
        ChitgramPreferences.shared.userDefaults.set(enabled, forKey: self.keyPrefix + "\(userId)")
        let notify = {
            NotificationCenter.default.post(name: ChitgramAccountNotifications.didChangeNotification, object: nil)
        }
        if Thread.isMainThread {
            notify()
        } else {
            DispatchQueue.main.async(execute: notify)
        }
    }

    /// The user ids of the accounts whose notifications are off on this device.
    public static func mutedUserIds() -> Set<Int64> {
        var result = Set<Int64>()
        for (key, value) in ChitgramPreferences.shared.userDefaults.dictionaryRepresentation() {
            guard key.hasPrefix(self.keyPrefix), let enabled = value as? Bool, !enabled else {
                continue
            }
            if let userId = Int64(String(key.dropFirst(self.keyPrefix.count))) {
                result.insert(userId)
            }
        }
        return result
    }

    /// The muted accounts now and after every change of a switch.
    public static var mutedUserIdsSignal: Signal<Set<Int64>, NoError> {
        return Signal { subscriber in
            subscriber.putNext(ChitgramAccountNotifications.mutedUserIds())
            let observer = NotificationCenter.default.addObserver(forName: ChitgramAccountNotifications.didChangeNotification, object: nil, queue: nil, using: { _ in
                subscriber.putNext(ChitgramAccountNotifications.mutedUserIds())
            })
            return ActionDisposable {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        |> distinctUntilChanged
    }
}
