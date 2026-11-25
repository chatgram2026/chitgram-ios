import Foundation
import Display
import TelegramCore
import AccountContext
import ChitgramCore

/// Chitgram (Android `AvatarOpensProfile`): whether a tap on this row's avatar opens the chat's profile. Never while
/// the list is being edited; a story ring and a community keep their own tap (the caller checks the ring).
func chitgramAvatarOpensProfile(item: ChatListItem) -> Bool {
    guard ChitgramChatListOptions.avatarOpensProfile, !item.editing else {
        return false
    }
    guard case let .peer(peerData) = item.content, let peer = peerData.peer.peer else {
        return false
    }
    if case .community = peer {
        return false
    }
    return true
}

/// Opens the profile over the current screen, as opening it from the chat header does.
func chitgramOpenProfile(context: AccountContext, peer: EnginePeer) {
    guard let controller = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) else {
        return
    }
    (context.sharedContext.mainWindow?.viewController as? NavigationController)?.pushViewController(controller)
}
