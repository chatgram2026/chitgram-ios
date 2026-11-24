import Foundation
import UIKit
import Display
import AccountContext
import TelegramCore
import PresentationDataUtils
import ChitgramCore

// Chitgram: the chat screen's own helpers.
extension ChatControllerImpl {
    /// "Do you really want to send?" (Android's confirmation dialogs); `completion` runs on OK.
    func chitgramConfirmSend(completion: @escaping () -> Void) {
        let strings = self.presentationInterfaceState.strings
        self.present(textAlertController(context: self.context, title: "Chitgram", text: ChitgramStrings.get(195), actions: [
            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: completion)
        ]), in: .window(.root))
    }

    /// ".heart" (Android `HeartAnimator`): the text is swapped for a red heart and sent, and the sent bubble then
    /// cycles through the coloured hearts on this device only. True when the send was taken over.
    func chitgramHeartBeforeSend(_ state: ChatTextInputState) -> Bool {
        guard state.inputText.string.trimmingCharacters(in: .whitespacesAndNewlines) == ".heart", let peerId = self.chatLocation.peerId, peerId.namespace != Namespaces.Peer.SecretChat else {
            return false
        }
        self.updateTextInputState(ChatTextInputState(inputText: NSAttributedString(string: "\u{2764}\u{FE0F}")))
        let account = self.context.account
        // The input box holds the heart on the next turn; the normal send then takes it.
        DispatchQueue.main.async { [weak self] in
            self?.chatDisplayNode.sendCurrentMessage()
            chitgramAnimateSentHeart(account: account, peerId: peerId)
        }
        return true
    }
}
