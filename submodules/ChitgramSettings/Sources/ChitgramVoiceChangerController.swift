import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import ChitgramCore
import ChitgramVoice

private final class ChitgramVoiceChangerArguments {
    let select: (Int) -> Void

    init(select: @escaping (Int) -> Void) {
        self.select = select
    }
}

private enum ChitgramVoiceChangerEntry: ItemListNodeEntry {
    case preset(index: Int, id: Int, title: String, selected: Bool)
    case footer(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case let .preset(index, _, _, _):
            return Int32(index)
        case .footer:
            return 1000
        }
    }

    static func <(lhs: ChitgramVoiceChangerEntry, rhs: ChitgramVoiceChangerEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramVoiceChangerArguments
        switch self {
        case let .preset(_, id, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(id)
            })
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// Chitgram's voice changer picker (Android `VoiceChangerSheet`): one row per effect in Graph's order with its emoji,
/// for voice messages or for calls. "Record speed" asks for one of four speeds; Modulation, Echo and Noise ask for their
/// settings, which their rows show. Calls have no speed row.
public func chitgramVoiceChangerController(context: AccountContext, forCall: Bool) -> ViewController {
    var presentImpl: ((ViewController) -> Void)?
    let choice = ChitgramVoiceChanger.of(forCall: forCall)

    // One question at a time from a list of values; `picked` gets the value chosen.
    let ask: (String, String?, [(String, Int)], @escaping (Int) -> Void) -> Void = { title, hint, values, picked in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: title, font: .large, parseMarkdown: false)]
        if let hint {
            items.append(ActionSheetTextItem(title: hint, parseMarkdown: false))
        }
        for (label, value) in values {
            items.append(ActionSheetButtonItem(title: label, color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                picked(value)
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentImpl?(actionSheet)
    }
    let steps = Array(ChitgramVoiceParams.stepMin ... ChitgramVoiceParams.stepMax)

    let arguments = ChitgramVoiceChangerArguments(select: { id in
        if id == ChitgramVoicePreset.speedRow {
            let values = ChitgramVoicePreset.speeds.map { (ChitgramStrings.get($0.titleId), $0.id) }
            ask(ChitgramStrings.get(822), nil, values, { picked in
                choice.presetId = picked
            })
        } else if id == ChitgramVoicePreset.modulation {
            let values = Array(ChitgramVoiceParams.toneMin ... ChitgramVoiceParams.toneMax).map { (ChitgramVoicePreset.toneText($0), $0) }
            ask(ChitgramStrings.get(825), ChitgramStrings.get(837), values, { tone in
                var params = choice.params
                params.tone = tone
                choice.params = params
                choice.presetId = id
            })
        } else if id == ChitgramVoicePreset.echo {
            let volumes = steps.map { (ChitgramVoicePreset.percentText($0), $0) }
            ask(ChitgramStrings.get(821), ChitgramStrings.get(836), volumes, { volume in
                let delays = steps.map { (ChitgramVoicePreset.secondsText($0), $0) }
                ask(ChitgramStrings.get(821), ChitgramStrings.get(835), delays, { delay in
                    var params = choice.params
                    params.echoVolume = volume
                    params.echoDelay = delay
                    choice.params = params
                    choice.presetId = id
                })
            })
        } else if id == ChitgramVoicePreset.noise {
            let volumes = steps.map { (ChitgramVoicePreset.percentText($0), $0) }
            ask(ChitgramStrings.get(826), ChitgramStrings.get(836), volumes, { volume in
                var params = choice.params
                params.noiseVolume = volume
                choice.params = params
                choice.presetId = id
            })
        } else {
            choice.presetId = id
        }
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, ChitgramPreferences.shared.changes)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        ChitgramStrings.setLanguageCode(presentationData.strings.primaryComponent.languageCode)
        let selected = choice.preset.id
        let params = choice.params
        var entries: [ChitgramVoiceChangerEntry] = []
        var index = 0
        for row in ChitgramVoicePreset.rows {
            if forCall && row.id == ChitgramVoicePreset.speedRow {
                continue
            }
            var title = row.emoji + " " + ChitgramStrings.get(row.titleId)
            let checked: Bool
            if row.id == ChitgramVoicePreset.speedRow {
                checked = ChitgramVoicePreset.isSpeed(selected)
                if checked {
                    title += " \u{2014} " + ChitgramStrings.get(ChitgramVoicePreset.byId(selected).titleId)
                }
            } else {
                checked = row.id == selected
                if let settings = ChitgramVoicePreset.settingsText(row.id, params: params) {
                    title += " (" + settings + ")"
                }
            }
            entries.append(.preset(index: index, id: row.id, title: title, selected: checked))
            index += 1
        }
        entries.append(.footer(ChitgramStrings.get(forCall ? 834 : 832)))

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(forCall ? 833 : 831)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
