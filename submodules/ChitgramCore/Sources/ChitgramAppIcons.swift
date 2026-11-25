import Foundation

/// The home screen icons Chitgram offers in Appearance ▸ App Icon, in Android's order (`LauncherIconController`): the
/// Chitgram mark on each of Android's colours. Each name is a `Telegram/Telegram-iOS/<name>.alticon` folder made from
/// Android's adaptive icon (its background under the white "Ch"). The first one is the app's own icon, so choosing it
/// puts the primary icon back.
public let chitgramAppIcons: [String] = [
    "ChitgramDefaultIcon",
    "ChitgramAmethystIcon",
    "ChitgramEmeraldIcon",
    "ChitgramCrimsonIcon",
    "ChitgramMintIcon",
    "ChitgramVioletIcon",
    "ChitgramCherryIcon",
    "ChitgramGoldIcon",
    "ChitgramGreenIcon",
    "ChitgramJadeIcon",
    "ChitgramSkyIcon",
    "ChitgramIndigoIcon",
    "ChitgramPremiumIcon",
    "ChitgramFireIcon",
    "ChitgramOceanIcon",
    "ChitgramSunsetIcon",
    "ChitgramBlackIcon",
    "ChitgramCoffeeIcon"
]

public let chitgramAppIconNames: Set<String> = Set(chitgramAppIcons)

/// The icon's name under its picture (Android `LauncherIcon.chitgramTitle`), nil for an icon that is not Chitgram's.
public func chitgramAppIconTitle(_ name: String) -> String? {
    let ids: [String: Int] = [
        "ChitgramDefaultIcon": 669,
        "ChitgramAmethystIcon": 670,
        "ChitgramEmeraldIcon": 671,
        "ChitgramCrimsonIcon": 672,
        "ChitgramMintIcon": 673,
        "ChitgramVioletIcon": 674,
        "ChitgramCherryIcon": 688,
        "ChitgramGoldIcon": 689,
        "ChitgramGreenIcon": 690,
        "ChitgramJadeIcon": 691,
        "ChitgramSkyIcon": 692,
        "ChitgramIndigoIcon": 693,
        "ChitgramPremiumIcon": 694,
        "ChitgramFireIcon": 695,
        "ChitgramOceanIcon": 696,
        "ChitgramSunsetIcon": 697,
        "ChitgramBlackIcon": 862,
        "ChitgramCoffeeIcon": 863
    ]
    guard let id = ids[name] else {
        return nil
    }
    return ChitgramStrings.get(id)
}
