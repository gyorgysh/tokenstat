// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with EditorFindSession.swift.
import Foundation

@main
struct EditorFindSessionTests {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            assert(condition, message)
        }
        let text = "Tokenstat keeps tokens. TOKENS cost. tokenize the tokens."
        do {
            let find = EditorFindSession()
            check(!find.hasQuery, "empty to start")
            check(find.current == nil, "no current without a query")
            check(find.countLabel == nil, "no count without a query")
            find.query = "tokens"
            find.refresh(text: text)
            check(find.matches.count == 4, "literal case-insensitive matches")
            check(find.countLabel == "1 of 4", "first match")
            find.goNext()
            check(find.countLabel == "2 of 4", "next")
            find.goNext()
            find.goNext()
            find.goNext()
            check(find.countLabel == "1 of 4", "next wraps")
            find.goPrevious()
            check(find.countLabel == "4 of 4", "previous wraps")
            check(find.canNavigate, "several matches navigate")
            check(find.canReplace, "matches replace")
        }
        do {
            let find = EditorFindSession()
            find.query = "missing"
            find.refresh(text: text)
            check(find.countLabel == "No results", "honest empty")
            check(!find.canNavigate && !find.canReplace, "nothing to act on")
            find.goNext()
            check(find.current == nil, "navigation is a no-op")
        }
        do {
            let find = EditorFindSession()
            find.query = "tokens"
            find.composing = true
            find.refresh(text: text)
            check(!find.canReplace, "composition blocks replacement")
            check(find.canNavigate, "navigation still works")
        }
        do {
            // The current match survives typing around it; a deleted match
            // clamps instead of pointing past the end.
            let find = EditorFindSession()
            find.query = "tokens"
            find.refresh(text: text)
            find.goNext()
            let kept = find.current
            find.refresh(text: text + "!")
            check(find.current == kept, "same match kept")
            find.refresh(text: "Nothing here")
            check(find.current == nil, "deleted matches clear")
            check(find.countLabel == "No results", "deleted matches read empty")
        }
        do {
            // A pathological buffer cannot mint unbounded ranges.
            let find = EditorFindSession()
            find.query = "a"
            find.refresh(text: String(repeating: "a ", count: 5000))
            check(find.matches.count == EditorFindSession.matchLimit, "matches are capped")
            check(find.truncated, "cap is honest")
            check(find.countLabel == "1 of 2000+", "capped count")
        }
        do {
            var actions: [EditorFindSession.Action] = []
            let find = EditorFindSession()
            find.query = "tokens"
            find.refresh(text: text)
            find.handler = { actions.append($0) }
            find.goNext()
            find.replaceCurrent()
            find.replaceAll()
            check(actions == [.next, .replaceCurrent, .replaceAll], "bar actions reach the view")
        }
        print("EditorFindSessionTests passed")
    }
}
