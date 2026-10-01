# Native app copy

The native apps still ship in English. App-owned labels, dialogs, notices,
tooltips, accessibility text, and starting prompts live in `en/common.json`
and the `apple.json`, `android.json`, or `windows.json` table. Apple includes
Mac, iPhone, and iPad. The apps bundle these files during their normal builds.

Use `L10n.text("key", ...)` in Swift/Kotlin and `L10n.Text("key", ...)` in C#.
Keep existing keys when editing copy; the suffix is an identifier, not a checksum
that needs updating. Use common keys for shared actions and platform keys for
copy whose wording or context differs. Prefer complete sentences to fragments.
Numbered placeholders such as `{0}` can be reordered or repeated in a translation.
Format numbers/dates before passing them, and never use user content as a key.
Inserted values are literal text; their braces and percent signs are not parsed.

To add a language, create a BCP 47 directory (for example `hu` or `hu-HU`) beside
`en`, with the same table names and keys. Missing entries fall back to English;
regional and script entries override the base language. Apple uses the first
available language in the system's preferences; Android and Windows use the
current system UI locale. No language picker or translated locale ships yet.
Preserve placeholders, native format specifiers, workflow tokens, and Markdown
syntax, including the commands shown inside code spans. Translate the existing
count branches together; do not create plural words by adding an English suffix
in new code.

Apple's system permission prompts use the native
`apps/mac/Resources/en.lproj/InfoPlist.strings` table. Add corresponding `.lproj`
tables and declare the supported bundle languages when shipping an Apple locale.
The Info.plist build settings retain the English fallback required by the OS.

Protocol methods, persisted enum raw values, IDs, paths, commands, font/icon names,
third-party names and license texts, and user/server content retain their original
values. `L10n.enumLabel` gives Apple enums a separate translated display label
without changing their raw values.

Run `python3 scripts/check-localization.py`, `scripts/run-swift-tests.sh`,
`scripts/run-windows-state-tests.sh`, and Android `testDebugUnitTest` after changes.
The catalog tests cover bundled English, locale preference, regional fallback,
Unicode, reordered/repeated placeholders, and values that contain template syntax.
