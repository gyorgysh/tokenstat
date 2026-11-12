// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatDictationText.swift.
import Foundation

@main
struct ChatDictationTextTests {
    static func main() {
        // An empty draft takes the words as they are.
        var empty = ChatDictationText(draft: "")
        precondition(empty.apply("hello", to: "") == "hello")
        precondition(empty.apply("hello world", to: "hello") == "hello world")

        // Typed text keeps its place, with exactly one space before the words.
        var typed = ChatDictationText(draft: "Fix the tests.")
        precondition(typed.apply(" then commit ", to: "Fix the tests.") == "Fix the tests. then commit")
        var spaced = ChatDictationText(draft: "Line one\n")
        precondition(spaced.apply("line two", to: "Line one\n") == "Line one\nline two")

        // A revised reading replaces the last one, it is never appended to it.
        var revised = ChatDictationText(draft: "Note:")
        precondition(revised.apply("there", to: "Note:") == "Note: there")
        precondition(revised.apply("their code", to: "Note: there") == "Note: their code")
        // A reading that comes back empty restores the draft as typed.
        precondition(revised.apply("", to: "Note: their code") == "Note:")

        // A hand edit in between stops dictation rather than overwriting it.
        var edited = ChatDictationText(draft: "Hi")
        precondition(edited.apply("there", to: "Hi") == "Hi there")
        precondition(edited.apply("there friend", to: "Hi there!") == nil)
        precondition(edited.spoken == "there")
        var cleared = ChatDictationText(draft: "Draft")
        precondition(cleared.apply("one", to: "") == nil)

        // Non-Latin scripts and accents pass through untouched.
        var hungarian = ChatDictationText(draft: "")
        precondition(hungarian.apply("Írj egy tesztet a függvényhez", to: "") == "Írj egy tesztet a függvényhez")

        // Finished sentences stay and new ones follow them.
        var running = ChatDictationTranscript()
        running.hear("Hello")
        running.hear("Hello there.")
        running.finish("Hello there.")
        precondition(running.text == "Hello there.")
        running.hear("Write")
        precondition(running.text == "Hello there. Write")
        running.hear("Write a test.")
        running.finish("Write a test.")
        running.hear("")
        precondition(running.text == "Hello there. Write a test.")

        // The older recognizer starts its guess over after a pause.
        var older = ChatDictationTranscript()
        older.hearRunning("Fix the login bug")
        older.hearRunning("Fix the log in bug please")
        precondition(older.text == "Fix the log in bug please")
        older.hearRunning("Then")
        precondition(older.text == "Fix the log in bug please Then")
        older.hearRunning("Then run the tests")
        precondition(older.text == "Fix the log in bug please Then run the tests")
        // A revision that keeps its opening is not a new sentence.
        var revision = ChatDictationTranscript()
        revision.hearRunning("Their code is fine")
        revision.hearRunning("Their code's fine")
        precondition(revision.text == "Their code's fine")

        // Running text feeds the draft without losing what was typed.
        var draft = ChatDictationText(draft: "Note:")
        precondition(draft.apply(running.text, to: "Note:") == "Note: Hello there. Write a test.")

        print("Chat dictation: placement, revision, hand edits, accents, kept sentences and restarts passed.")
    }
}
