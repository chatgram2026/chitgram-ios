import Foundation
import UIKit
import Display
import AccountContext
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
}
