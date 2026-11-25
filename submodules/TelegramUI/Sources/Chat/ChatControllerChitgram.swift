import Foundation
import UIKit
import Display
import AccountContext
import TelegramCore
import PresentationDataUtils
import ChitgramCore
import ChitgramSettings

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

    /// Lets the composer's mic and the profile menu's "Voice to text" put text into this chat's input box.
    func chitgramRegisterInputBridge() {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        ChitgramChatBridge.register(chat: peerId.toInt64(), insert: { [weak self] text in
            guard let self else {
                return false
            }
            let state = self.presentationInterfaceState.interfaceState.composeInputState
            let length = state.inputText.length
            let separator = length > 0 ? " " : ""
            self.updateTextInputState(state.replacingFlatRange(NSRange(location: length, length: 0), with: separator + text))
            return true
        })
        let chat = peerId.toInt64()
        ChitgramChatBridge.registerDictation(chat: chat, start: { [weak self] in
            self?.chitgramDictateIntoInput(chat: chat)
        })
    }

    /// The composer mic: dictation with the saved languages, the text then added to the input box.
    private func chitgramDictateIntoInput(chat: Int64) {
        chitgramStartDictation(context: self.context, present: { [weak self] c in
            self?.present(c, in: .window(.root))
        }, completion: { text in
            let _ = ChitgramChatBridge.insert(chat: chat, text: text)
        })
    }
}
