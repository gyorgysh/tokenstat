# Teams UI fixture

This app renders the production Teams views with fictional account responses.
Its build excludes Bridge, FFI, account login and credential storage. Copy and
browser actions are intercepted, and the fixture avatars have no image URLs.
Directory writes return an inline fixture error.

Build the Mac fixture with:

```sh
scripts/run-team-ui-fixture.sh --build-only
```

Use `--open` to open the fixture. The toolbar offers light and dark appearance,
three window widths, and individual forms. Its bundle identifier is
`ai.tokenstat.qa.teams`. Launch arguments `--fixture-state empty`,
`authorization`, `unavailable`, `failure`, `paused`, or `member` select recovery
and permission states. The default is `ready`.

Build the same views for the iOS simulator with:

```sh
xcodegen generate --spec scripts/qa/teams/project.yml
xcodebuild -project scripts/qa/teams/TeamUIFixture.xcodeproj \
  -scheme TeamUIFixture -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath target/xcode-teams-fixture-ios \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

The project is generated beside the specification because XcodeGen folder
resources resolve relative to that directory. Generated projects and binaries
are ignored. Run the fixture on a separate Simulator device selected by its
explicit identifier.

Check members, search, scope switching, empty states, invitation validation,
repository roles, ownership and deletion confirmations. Test narrow windows,
both appearances, larger text, keyboard navigation and VoiceOver. These fixtures
supplement the account and transport integration tests; their API deliberately
refuses writes.
