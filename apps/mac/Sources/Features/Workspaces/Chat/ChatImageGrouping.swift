// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A presentation pass: archive rows and their identifiers stay intact for
/// search and caching. Only adjacent images or explicitly attributed tool
/// files share a gallery; a nearby tool alone is never evidence of ownership.
enum ChatImageGrouping {
    private struct ToolKey: Hashable { let call: String; let backend: String? }
    static func prepare(_ rows: [ChatDisplayItem]) -> [ChatDisplayItem] {
        var result: [ChatDisplayItem] = []
        var tools: [ToolKey: Int] = [:]
        for row in rows {
            switch row.kind {
            case .user where !row.isSteer, .handoff, .turnSeparator:
                tools = [:]
            case let .tool(tool):
                if !tool.callId.isEmpty { tools[ToolKey(call: tool.callId, backend: row.sourceBackend)] = result.count }
            default: break
            }
            guard case let .attachment(file) = row.kind, file.mediaType?.hasPrefix("image/") == true else {
                result.append(row)
                continue
            }
            if let call = file.toolCallId, let index = tools[ToolKey(call: call, backend: row.sourceBackend)] {
                append(file, rowID: row.id, to: &result[index])
            } else if let last = result.indices.last, case let .attachment(previous) = result[last].kind,
                      previous.mediaType?.hasPrefix("image/") == true,
                      previous.toolCallId == file.toolCallId, result[last].sourceBackend == row.sourceBackend {
                append(file, rowID: row.id, to: &result[last])
            } else {
                var gallery = row
                append(file, rowID: row.id, to: &gallery)
                result.append(gallery)
            }
        }
        return result
    }

    private static func append(_ file: ChatAttachment, rowID: String, to row: inout ChatDisplayItem) {
        if !row.imageAttachments.contains(where: { $0.id == file.id }) { row.imageAttachments.append(file) }
        if !row.imageRowIDs.contains(rowID) { row.imageRowIDs.append(rowID) }
    }

    static func rowID(for id: String, in rows: [ChatDisplayItem]) -> String {
        rows.first(where: { $0.id == id || $0.imageRowIDs.contains(id) })?.id ?? id
    }
}
