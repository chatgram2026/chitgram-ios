import Foundation
import Postbox
import SwiftSignalKit
import ChitgramCore

// MARK: - Deleted media kept (Android "Keep deleted media too", ChitgramArchive)

// Copies of the downloaded photos, videos and files of messages others deleted, kept beside the account's media box
// rather than in it, so clearing Telegram's cache does not take them. Whenever a copy's resource is missing from the
// media box it is put back (`chitgramRestoreDeletedMedia`), so the kept message shows its media again. As on Android,
// files over 64 MB are left in the cache, and the copies take 2 GB at most, the oldest dropped first.

private let chitgramDeletedMediaQueue = DispatchQueue(label: "org.chitgram.deletedMedia")
private let chitgramDeletedMediaMaxFileBytes: Int64 = 64 * 1024 * 1024
private let chitgramDeletedMediaBudgetBytes: Int64 = 2 * 1024 * 1024 * 1024
private let chitgramDeletedMediaFileNameCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

private func chitgramDeletedMediaDirectory(_ mediaBox: MediaBox) -> String {
    return (mediaBox.basePath as NSString).deletingLastPathComponent + "/chitgram-deleted-media"
}

private func chitgramDeletedMediaFileName(_ id: MediaResourceId) -> String {
    return String(id.stringRepresentation.map { chitgramDeletedMediaFileNameCharacters.contains($0) ? $0 : "_" })
}

private func chitgramFileBytes(_ path: String) -> Int64 {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
        return 0
    }
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
}

/// The copies' file names and the resource each stands for.
private func chitgramReadDeletedMediaIndex(_ directory: String) -> [String: String] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: directory + "/index.json")) else {
        return [:]
    }
    return ((try? JSONSerialization.jsonObject(with: data)) as? [String: String]) ?? [:]
}

private func chitgramWriteDeletedMediaIndex(_ index: [String: String], _ directory: String) {
    if let data = try? JSONSerialization.data(withJSONObject: index) {
        let _ = try? data.write(to: URL(fileURLWithPath: directory + "/index.json"), options: [.atomic])
    }
}

/// Keeps the copies within the budget, dropping the oldest first.
private func chitgramTrimDeletedMedia(directory: String, index: inout [String: String]) {
    let fileManager = FileManager.default
    var files: [(name: String, size: Int64, date: Date)] = []
    var total: Int64 = 0
    for name in Array(index.keys) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: directory + "/" + name) else {
            index[name] = nil
            continue
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attributes[.creationDate] as? Date) ?? Date.distantPast
        files.append((name: name, size: size, date: date))
        total += size
    }
    if total <= chitgramDeletedMediaBudgetBytes {
        return
    }
    for file in files.sorted(by: { $0.date < $1.date }) {
        if total <= chitgramDeletedMediaBudgetBytes {
            break
        }
        let _ = try? fileManager.removeItem(atPath: directory + "/" + file.name)
        index[file.name] = nil
        total -= file.size
    }
}

/// Called where a message others deleted is kept (AccountStateManagementUtils): copies its downloaded media while
/// "Keep deleted media too" is on. Off the transaction's queue.
func chitgramArchiveDeletedMedia(mediaBox: MediaBox, message: Message) {
    guard ChitgramPreferences.shared.bool(.archiveMedia) else {
        return
    }
    var resourceIds: [MediaResourceId] = []
    addMessageMediaResourceIdsToRemove(message: message, resourceIds: &resourceIds)
    if resourceIds.isEmpty {
        return
    }
    chitgramDeletedMediaQueue.async {
        let directory = chitgramDeletedMediaDirectory(mediaBox)
        let fileManager = FileManager.default
        let _ = try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
        var index = chitgramReadDeletedMediaIndex(directory)
        var changed = false
        for id in Set(resourceIds) {
            guard let path = mediaBox.completedResourcePath(id: id) else {
                continue
            }
            let size = chitgramFileBytes(path)
            if size <= 0 || size > chitgramDeletedMediaMaxFileBytes {
                continue
            }
            let name = chitgramDeletedMediaFileName(id)
            let target = directory + "/" + name
            if !fileManager.fileExists(atPath: target) {
                if (try? fileManager.copyItem(atPath: path, toPath: target)) == nil {
                    continue
                }
            }
            index[name] = id.stringRepresentation
            changed = true
        }
        if changed {
            chitgramTrimDeletedMedia(directory: directory, index: &index)
            chitgramWriteDeletedMediaIndex(index, directory)
        }
    }
}

/// Puts every kept copy whose resource the media box lost (a cache clear) back into it. At launch and on every return.
public func chitgramRestoreDeletedMedia(account: Account) {
    let mediaBox = account.postbox.mediaBox
    chitgramDeletedMediaQueue.async {
        let directory = chitgramDeletedMediaDirectory(mediaBox)
        for (name, idString) in chitgramReadDeletedMediaIndex(directory) {
            let id = MediaResourceId(idString)
            if mediaBox.completedResourcePath(id: id) == nil {
                mediaBox.copyResourceData(id, fromTempPath: directory + "/" + name)
            }
        }
    }
}

// MARK: - The saved history (Android "Clear saved history", 864)

// What this phone keeps of other people's deletes and edits: messages kept with `DeletedMessageAttribute`, the
// `EditedMessageHistoryAttribute` of edited ones, and the kept media copies. The messages are found chat by chat, a
// few chats per transaction, so the database stays free for the screens in between.

private func chitgramScanSavedHistory(transaction: Transaction, peerIds: ArraySlice<PeerId>) -> (deleted: [MessageId], edited: [MessageId]) {
    var deleted: [MessageId] = []
    var edited: [MessageId] = []
    for peerId in peerIds {
        transaction.scanMessageAttributes(peerId: peerId, namespace: Namespaces.Message.Cloud, limit: Int.max, { id, attributes in
            if attributes.contains(where: { $0 is DeletedMessageAttribute }) {
                deleted.append(id)
            } else if attributes.contains(where: { $0 is EditedMessageHistoryAttribute }) {
                edited.append(id)
            }
            return true
        })
    }
    return (deleted, edited)
}

private func chitgramForEachChatBatch(account: Account, _ body: @escaping (Transaction, ArraySlice<PeerId>) -> Int64) -> Signal<Int64, NoError> {
    let postbox = account.postbox
    return postbox.transaction { transaction -> [PeerId] in
        return transaction.chatListGetAllPeerIds()
    }
    |> mapToSignal { peerIds -> Signal<Int64, NoError> in
        func step(_ start: Int, _ total: Int64) -> Signal<Int64, NoError> {
            if start >= peerIds.count {
                return .single(total)
            }
            let end = min(start + 20, peerIds.count)
            return postbox.transaction { transaction -> Int64 in
                return body(transaction, peerIds[start ..< end])
            }
            |> mapToSignal { value -> Signal<Int64, NoError> in
                return step(end, total + value)
            }
        }
        return step(0, 0)
    }
}

/// The bytes of the media files of `media` that are on this phone.
private func chitgramDownloadedBytes(_ media: [Media], mediaBox: MediaBox) -> Int64 {
    var resources: [MediaResource] = []
    for item in media {
        if let image = item as? TelegramMediaImage {
            for representation in image.representations {
                resources.append(representation.resource)
            }
        } else if let file = item as? TelegramMediaFile {
            for representation in file.previewRepresentations {
                resources.append(representation.resource)
            }
            resources.append(file.resource)
        }
    }
    var total: Int64 = 0
    for resource in resources {
        total += chitgramFileBytes(mediaBox.resourcePath(resource))
    }
    return total
}

private func chitgramDirectoryBytes(_ directory: String) -> Int64 {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
        return 0
    }
    var total: Int64 = 0
    for name in names {
        total += chitgramFileBytes(directory + "/" + name)
    }
    return total
}

/// How much the saved history takes on this phone, in bytes.
public func chitgramSavedHistorySize(account: Account) -> Signal<Int64, NoError> {
    let mediaBox = account.postbox.mediaBox
    let messages = chitgramForEachChatBatch(account: account, { transaction, peerIds in
        let found = chitgramScanSavedHistory(transaction: transaction, peerIds: peerIds)
        var total: Int64 = 0
        for id in found.deleted {
            if let message = transaction.getMessage(id) {
                total += Int64(message.text.utf8.count)
                total += chitgramDownloadedBytes(message.media, mediaBox: mediaBox)
            }
        }
        for id in found.deleted + found.edited {
            if let message = transaction.getMessage(id), let history = message.attributes.first(where: { $0 is EditedMessageHistoryAttribute }) as? EditedMessageHistoryAttribute {
                for entry in history.history {
                    total += Int64(entry.text.utf8.count)
                }
            }
        }
        return total
    })
    let copies = Signal<Int64, NoError> { subscriber in
        chitgramDeletedMediaQueue.async {
            subscriber.putNext(chitgramDirectoryBytes(chitgramDeletedMediaDirectory(mediaBox)))
            subscriber.putCompletion()
        }
        return EmptyDisposable
    }
    return combineLatest(messages, copies)
    |> map { messages, copies -> Int64 in
        return messages + copies
    }
}

/// Removes the kept deleted messages from this phone's chats, the edit history from edited ones, and the media copies.
public func chitgramClearSavedHistory(account: Account) -> Signal<Never, NoError> {
    let mediaBox = account.postbox.mediaBox
    return chitgramForEachChatBatch(account: account, { transaction, peerIds in
        let found = chitgramScanSavedHistory(transaction: transaction, peerIds: peerIds)
        if !found.deleted.isEmpty {
            _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: found.deleted)
        }
        for id in found.edited {
            transaction.updateMessage(id, update: { message in
                let storeForwardInfo = message.forwardInfo.flatMap(StoreMessageForwardInfo.init)
                let attributes = message.attributes.filter { !($0 is EditedMessageHistoryAttribute) }
                return .update(StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId, groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp, flags: StoreMessageFlags(message.flags), tags: message.tags, globalTags: message.globalTags, localTags: message.localTags, forwardInfo: storeForwardInfo, authorId: message.author?.id, text: message.text, attributes: attributes, media: message.media))
            })
        }
        return Int64(found.deleted.count + found.edited.count)
    })
    |> mapToSignal { _ -> Signal<Never, NoError> in
        return Signal { subscriber in
            chitgramDeletedMediaQueue.async {
                let _ = try? FileManager.default.removeItem(atPath: chitgramDeletedMediaDirectory(mediaBox))
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }
}
