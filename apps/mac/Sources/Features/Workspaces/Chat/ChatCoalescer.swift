// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

extension ChatDisplayItem {
    /// A name for a row that survives an older page arriving in front of it.
    ///
    /// The record's place in the archive when the host reports one, which is
    /// fixed for the life of that record. Without it the row is named by its
    /// position in the list, which is what it always was, and what makes a
    /// prepend re-identify every row below it.
    private static func stamp(_ event: ChatTimelineEvent, _ position: Int) -> String {
        if let seq = event.seq { return "s\(seq)" }
        return "\(event.atMs ?? 0)-\(position)"
    }

    static func coalesce(_ events: [ChatTimelineEvent], defaultBackend: String? = nil, running: Bool = true) -> [ChatDisplayItem] {
        var items: [ChatDisplayItem] = []
        // Completed history does not participate in live-tool closure or
        // fallback edit matching. Keep only the rows still running.
        var runningIndexes: Set<Int> = []
        // Every row a call id has started, oldest first. A call id is not
        // unique on every backend (Antigravity sends `call_id: "tool"` for
        // all of them), so an End has to close the oldest row still running
        // under that name rather than keep overwriting the newest start.
        var toolIndexes: [String: [Int]] = [:]
        // How many times each call id has already started a tool in this
        // conversation. An agent is supposed to name every call something of
        // its own, and most do, but Antigravity sends `call_id: "tool"` for
        // all of them.
        var toolStarts: [String: Int] = [:]
        // A completion may belong to a different backend than the last text
        // event in a mixed-provider transcript. Keep each start's provenance.
        var toolBackends: [Int: String] = [:]
        // Same duplicate-id hazard as tools, for edits that carry a reused
        // call id (or none and the same path twice). Row ids feed ForEach.
        var editStarts: [String: Int] = [:]
        var approvalIndex: [String: Int] = [:]
        var questionIndex: [String: Int] = [:]
        var text = ""
        var textID = ""
        var textBackend: String?
        var textLastSequence: UInt64?
        var thinkingLastSequence: UInt64?
        var thinking = ""
        var thinkingID = ""
        var lastBackend: String?
        var editRevisions: [String: Int] = [:]

        func flushText() {
            // The question block is drawn as its own card below the reply.
            let body = ChatQuestionText.stripping(text, streaming: running).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                items.append(
                    ChatDisplayItem(
                        id: textID,
                        kind: .assistant(body, backend: textBackend ?? defaultBackend),
                        lastSequence: textLastSequence
                    )
                )
            }
            text = ""
            textID = ""
            textBackend = nil
            textLastSequence = nil
        }

        func flushThinking() {
            let body = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                items.append(ChatDisplayItem(id: thinkingID, kind: .thinking(body), lastSequence: thinkingLastSequence))
            }
            thinking = ""
            thinkingID = ""
            thinkingLastSequence = nil
        }

        func closeRunningTools(failed: Bool, at: Int64?, detail: String?) {
            for index in runningIndexes {
                switch items[index].kind {
                case .tool(var state) where state.running:
                    state.running = false
                    state.failed = failed
                    if state.detail == nil {
                        state.detail = detail
                        state.snippet = ChatToolState.makeSnippet(verb: state.verb, detail: detail)
                    }
                    state.endedAtMs = at
                    items[index] = ChatDisplayItem(id: items[index].id, kind: .tool(state))
                case .edit(var state) where state.running:
                    state.running = false
                    state.failed = failed
                    state.endedAtMs = at
                    state.applyDetail(detail)
                    items[index] = ChatDisplayItem(id: items[index].id, kind: .edit(state))
                default:
                    continue
                }
            }
            runningIndexes.removeAll(keepingCapacity: true)
        }

        func nextEditRevision(_ path: String) -> Int {
            let key = path
            let n = (editRevisions[key] ?? 0) + 1
            editRevisions[key] = n
            return n
        }

        func matchingEditIndex(callId: String, path: String) -> Int? {
            if !callId.isEmpty, let indexes = toolIndexes[callId] {
                for index in indexes.reversed() where items.indices.contains(index) {
                    switch items[index].kind {
                    case let .edit(state) where path.isEmpty || state.path == path || state.path == "File":
                        return index
                    case let .tool(state)
                        where ChatToolState.isFileEditVerb(state.verb)
                            && (path.isEmpty || state.target == path || state.target.isEmpty):
                        return index
                    default:
                        continue
                    }
                }
            }
            for index in runningIndexes.sorted(by: >) {
                switch items[index].kind {
                case let .edit(state) where state.running && (path.isEmpty || state.path == path):
                    return index
                case let .tool(state)
                    where state.running
                        && ChatToolState.isFileEditVerb(state.verb)
                        && (path.isEmpty || state.target == path):
                    return index
                default:
                    continue
                }
            }
            return nil
        }

        /// Remember a row as the newest one this call id names. An id that
        /// already named the row is moved to the back rather than repeated.
        func noteToolIndex(_ index: Int, callId: String) {
            guard !callId.isEmpty else { return }
            var indexes = toolIndexes[callId] ?? []
            indexes.removeAll { $0 == index }
            indexes.append(index)
            toolIndexes[callId] = indexes
        }

        /// The row an End closes: the oldest one still running under this
        /// call id, or, for a repeat End with nothing left running, the
        /// newest row the id named.
        func toolEndIndex(callId: String) -> Int? {
            guard !callId.isEmpty, let indexes = toolIndexes[callId] else { return nil }
            let running = indexes.first { index in
                guard items.indices.contains(index) else { return false }
                switch items[index].kind {
                case let .tool(state): return state.running
                case let .edit(state): return state.running
                default: return false
                }
            }
            return running ?? indexes.last { items.indices.contains($0) }
        }

        for event in events {
            if event.kind == "user" {
                flushText()
                flushThinking()
                // A new user turn bounds any tools left open by an interrupted
                // older turn, including histories recorded by older hosts.
                closeRunningTools(failed: false, at: event.atMs, detail: L10n.text("apple.chatmodel.interrupted.132d124d"))
                editRevisions = [:]
                items.append(
                    ChatDisplayItem(
                        id: "user-\(stamp(event, items.count))",
                        kind: .user(event.text ?? "")
                    )
                )
                continue
            }
            if event.kind == "handoff" {
                flushText()
                flushThinking()
                items.append(
                    ChatDisplayItem(
                        id: "handoff-\(stamp(event, items.count))",
                        kind: .handoff(to: event.to ?? "", brief: event.brief ?? "")
                    )
                )
                // The separator would say the same thing twice, less well.
                lastBackend = event.to ?? lastBackend
                continue
            }
            if let approval = event.approval {
                flushText()
                flushThinking()
                // The timeline records an approval twice: once when the agent
                // paused, and again with the answer. Keep the row in the place
                // it happened and let the later state win, so a conversation
                // reopened tomorrow shows the outcome rather than a question
                // that looks like it is still waiting.
                let rowID = "approval-\(approval.id)"
                if let at = approvalIndex[rowID] {
                    items[at] = ChatDisplayItem(id: rowID, kind: .approval(approval))
                } else {
                    approvalIndex[rowID] = items.count
                    items.append(ChatDisplayItem(id: rowID, kind: .approval(approval)))
                }
                continue
            }
            if event.kind == "question", let questionID = event.recordID, let asked = event.question {
                flushText()
                flushThinking()
                questionIndex[questionID] = items.count
                items.append(ChatDisplayItem(
                    id: "question-\(questionID)",
                    kind: .question(ChatQuestion(
                        id: questionID,
                        question: asked,
                        options: event.options ?? [],
                        multiple: event.multiple ?? false,
                        defaultAnswer: event.defaultAnswer,
                        blocking: event.blocking ?? (event.defaultAnswer == nil)
                    ))
                ))
                continue
            }
            if event.kind == "answer" || event.kind == "answerWithdrawn" {
                // Lands on its question's card. An answer whose question is
                // on an older page than this one waits for that page. A
                // withdrawn answer never reached the agent, so the card opens
                // again.
                if let questionID = event.questionID, let at = questionIndex[questionID],
                   case var .question(question) = items[at].kind {
                    let withdrawn = event.kind == "answerWithdrawn"
                    question.answer = withdrawn ? nil : event.text ?? ""
                    question.delivery = withdrawn ? nil : event.delivery
                    items[at] = ChatDisplayItem(id: items[at].id, kind: .question(question))
                }
                continue
            }
            guard let agent = event.event else { continue }
            let eventBackend = event.backend ?? defaultBackend
            if let eventBackend, let lastBackend, eventBackend != lastBackend {
                flushText()
                flushThinking()
                items.append(
                    ChatDisplayItem(
                        id: "turn-\(stamp(event, items.count))",
                        kind: .turnSeparator(eventBackend)
                    )
                )
            }
            if let eventBackend { lastBackend = eventBackend }
            switch agent.kind {
            case "text":
                flushThinking()
                if text.isEmpty {
                    textID = "text-\(stamp(event, items.count))"
                    textBackend = event.backend ?? defaultBackend
                }
                text += agent.delta ?? ""
                textLastSequence = event.seq
            case "thinking":
                flushText()
                if thinking.isEmpty { thinkingID = "think-\(stamp(event, items.count))" }
                thinking += agent.delta ?? ""
                thinkingLastSequence = event.seq
            case "toolStart":
                flushText()
                flushThinking()
                let callId = agent.callId ?? "tool-\(stamp(event, items.count))"
                // Archive positions keep a tool's row stable when older
                // pages bring another use of the same call ID. Legacy hosts
                // without positions keep the occurrence-based fallback.
                let occurrence = (toolStarts[callId] ?? 0) + 1
                toolStarts[callId] = occurrence
                let rowID = event.seq != nil ? "tool-\(stamp(event, items.count))"
                    : (occurrence == 1 ? "tool-\(callId)" : "tool-\(callId)#\(occurrence)")
                // Empty when the event named no tool. The row then says Working.
                let verb = agent.verb ?? ""
                let target = ChatToolState.clip(agent.target ?? "")
                noteToolIndex(items.count, callId: callId)
                runningIndexes.insert(items.count)
                toolBackends[items.count] = eventBackend ?? ""
                if ChatToolState.isFileEditVerb(verb) {
                    items.append(
                        ChatDisplayItem(
                            id: rowID,
                            kind: .edit(
                                ChatEditState(
                                    path: target.isEmpty ? "File" : target,
                                    added: 0,
                                    removed: 0,
                                    patch: "",
                                    revision: nextEditRevision(target.isEmpty ? L10n.text("apple.chatmodel.file.50009ce1") : target),
                                    running: true,
                                    failed: false,
                                    startedAtMs: event.atMs ?? 0,
                                    endedAtMs: nil
                                )
                            )
                        )
                    )
                } else {
                    items.append(
                        ChatDisplayItem(
                            id: rowID,
                            kind: .tool(
                                ChatToolState(
                                    callId: callId,
                                    verb: verb,
                                    // Same reason as the snippet: a shell "target"
                                    // is the whole command, and a heredoc makes
                                    // that a document. `lineLimit` bounds what
                                    // is drawn, not what is measured.
                                    target: target,
                                    running: true,
                                    failed: false,
                                    detail: nil,
                                    startedAtMs: event.atMs ?? 0,
                                    endedAtMs: nil,
                                    snippet: []
                                )
                            )
                        )
                    )
                }
            case "toolEnd":
                flushText()
                flushThinking()
                let callId = agent.callId ?? ""
                if let index = toolEndIndex(callId: callId) {
                    switch items[index].kind {
                    case .tool(var state):
                        let presentation = MuseToolPresentation.completed(
                            backend: toolBackends[index], verb: state.verb,
                            target: state.target, detail: agent.detail
                        )
                        state.verb = presentation.verb
                        state.target = ChatToolState.clip(presentation.target)
                        state.running = false
                        state.failed = !(agent.ok ?? true)
                        state.detail = agent.detail
                        state.snippet = ChatToolState.makeSnippet(verb: state.verb, detail: agent.detail)
                        state.endedAtMs = event.atMs
                        items[index] = ChatDisplayItem(id: items[index].id, kind: .tool(state))
                    case .edit(var state):
                        state.running = false
                        state.failed = !(agent.ok ?? true)
                        state.endedAtMs = event.atMs
                        state.applyDetail(agent.detail)
                        items[index] = ChatDisplayItem(id: items[index].id, kind: .edit(state))
                    default:
                        break
                    }
                    runningIndexes.remove(index)
                } else if ChatToolState.isFileEditVerb(agent.verb ?? "") {
                    let path = {
                        let clipped = ChatToolState.clip(agent.target ?? "")
                        return clipped.isEmpty ? L10n.text("apple.chatmodel.file.50009ce1") : clipped
                    }()
                    var state = ChatEditState(
                        path: path,
                        added: 0,
                        removed: 0,
                        patch: "",
                        revision: nextEditRevision(path),
                        running: false,
                        failed: !(agent.ok ?? true),
                        startedAtMs: event.atMs ?? 0,
                        endedAtMs: event.atMs
                    )
                    state.applyDetail(agent.detail)
                    items.append(
                        ChatDisplayItem(
                            id: "edit-\(event.seq != nil || callId.isEmpty ? stamp(event, items.count) : callId)",
                            kind: .edit(state)
                        )
                    )
                } else {
                    let fallback = callId.isEmpty ? "end-\(stamp(event, items.count))" : callId
                    // Empty when the event named no tool. The row then says Worked.
                    let presentation = MuseToolPresentation.completed(
                        backend: eventBackend, verb: agent.verb ?? "",
                        target: agent.target ?? "", detail: agent.detail
                    )
                    let fallbackVerb = presentation.verb
                    items.append(
                        ChatDisplayItem(
                            id: "tool-\(event.seq != nil ? stamp(event, items.count) : fallback)",
                            kind: .tool(
                                ChatToolState(
                                    callId: fallback,
                                    verb: fallbackVerb,
                                    target: ChatToolState.clip(presentation.target),
                                    running: false,
                                    failed: !(agent.ok ?? true),
                                    detail: agent.detail,
                                    startedAtMs: event.atMs ?? 0,
                                    endedAtMs: event.atMs,
                                    snippet: ChatToolState.makeSnippet(verb: fallbackVerb, detail: agent.detail)
                                )
                            )
                        )
                    )
                }
            case "edit":
                flushText()
                flushThinking()
                let callId = agent.callId ?? ""
                let path = agent.path ?? L10n.text("apple.chatmodel.file.50009ce1")
                let added = agent.added ?? 0
                let removed = agent.removed ?? 0
                let patch = agent.patch ?? ""
                if let index = matchingEditIndex(callId: callId, path: path) {
                    switch items[index].kind {
                    case .edit(var state):
                        state.applyPatch(added: added, removed: removed, patch: patch)
                        if state.path == "File", !path.isEmpty { state.path = path }
                        items[index] = ChatDisplayItem(id: items[index].id, kind: .edit(state))
                    case .tool(let toolState):
                        var state = ChatEditState(
                            path: path,
                            added: added,
                            removed: removed,
                            patch: patch,
                            revision: nextEditRevision(path),
                            running: toolState.running,
                            failed: false,
                            startedAtMs: toolState.startedAtMs,
                            endedAtMs: toolState.running ? nil : (event.atMs ?? toolState.endedAtMs)
                        )
                        state.recountIfNeeded()
                        items[index] = ChatDisplayItem(id: items[index].id, kind: .edit(state))
                    default:
                        break
                    }
                    if !callId.isEmpty { noteToolIndex(index, callId: callId) }
                } else {
                    var state = ChatEditState(
                        path: path,
                        added: added,
                        removed: removed,
                        patch: patch,
                        revision: nextEditRevision(path),
                        running: false,
                        failed: false,
                        startedAtMs: event.atMs ?? 0,
                        endedAtMs: nil
                    )
                    state.recountIfNeeded()
                    let rowID: String = {
                        if event.seq != nil || callId.isEmpty { return "edit-\(stamp(event, items.count))" }
                        let occurrence = (editStarts[callId] ?? 0) + 1
                        editStarts[callId] = occurrence
                        return occurrence == 1 ? "edit-\(callId)" : "edit-\(callId)#\(occurrence)"
                    }()
                    if !callId.isEmpty { noteToolIndex(items.count, callId: callId) }
                    items.append(ChatDisplayItem(id: rowID, kind: .edit(state)))
                }
            case "attachment":
                flushText()
                flushThinking()
                guard let id = agent.id else { continue }
                items.append(
                    ChatDisplayItem(
                        id: "attachment-\(id)",
                        kind: .attachment(
                            ChatAttachment(
                                id: id,
                                name: agent.name.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("apple.chatmodel.attachment.040d2b36"),
                                mediaType: agent.mediaType,
                                size: agent.size
                            )
                        )
                    )
                )
            case "usage":
                flushText()
                flushThinking()
                items.append(
                    ChatDisplayItem(
                        id: "usage-\(stamp(event, items.count))",
                        kind: .usage(
                            input: agent.input ?? 0,
                            output: agent.output ?? 0,
                            cost: agent.costUsd
                        )
                    )
                )
            case "failed":
                flushText()
                flushThinking()
                closeRunningTools(failed: true, at: event.atMs, detail: agent.text)
                items.append(
                    ChatDisplayItem(
                        id: "failed-\(stamp(event, items.count))",
                        kind: .failed(agent.text ?? L10n.text("apple.chatmodel.the_turn_failed.45783181"))
                    )
                )
            case "done":
                flushText()
                flushThinking()
                let status = agent.status ?? ""
                // Only the host's process outcome can fail a turn. Older hosts
                // may still carry a backend-level "cancelled" marker from
                // grok; that describes its tool stream, not the person
                // pressing Stop and not a failed process.
                let failed = status == "error"
                closeRunningTools(failed: failed, at: event.atMs, detail: failed ? status : nil)
            default:
                continue
            }
        }
        flushText()
        flushThinking()
        // Tool logs are history; only the host knows whether a process lives.
        if !running {
            closeRunningTools(failed: false, at: nil, detail: L10n.text("apple.chatmodel.ended_without_a_tool_result.da8d3680"))
        }
        return items
    }
}
