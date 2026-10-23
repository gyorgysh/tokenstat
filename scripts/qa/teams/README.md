# Teams UI fixture

This app renders the production Teams views with fictional account responses.
Its build excludes Bridge, FFI, account login and credential storage. Copy and
browser actions are intercepted, and the fixture avatars have no image URLs.
Directory and checkout publication writes return an inline fixture error.
The `comment` and `commentUncertain` scenarios accept fictional comments in
memory and keep their draft files in a separate temporary directory. The
uncertain scenario interrupts the reply after acceptance so receipt recovery
can be tested. `commentViewer` has no composer.
On iOS, the uncertain scenario also offers “Remove repository access” in the
fixture menu. Comment drafts must remain available afterward, with local chat
labels, copy actions and an explicit removal review. Removing a local draft
does not cancel the fictional accepted comment.
The `draftOffline` scenario starts with an already known account and a saved
attempt while every Teams capability request fails. Local recovery must stay
available without enabling Team reads or sends.

Build the Mac fixture with:

```sh
scripts/run-team-ui-fixture.sh --build-only
```

Use `--open` to open the fixture. The toolbar offers light and dark appearance,
three window widths, and individual forms. Its bundle identifier is
`ai.tokenstat.qa.teams`. Launch arguments `--fixture-state empty`,
`authorization`, `unavailable`, `failure`, `paused`, or `member` select recovery
and permission states. `invitation` and `expiredInvitation` show recipient
review states on iOS. The default is `ready`.

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

CI runs `python3 scripts/run-team-ui-tests.py` for each device family. It creates a new compatible
iPhone or iPad Simulator, verifies all 27 scenarios, and removes only that device.
`--select-only` reports an installed runtime without changing any device.
Use `--only-test testCommentPostsWithVerifiedAuthor` for a focused local run.
Omit that option for the complete CI check.

Check the Team hub, organization overview, project filtering, foreground app presence, members, search, empty states, invitation validation,
repository roles, ownership, checkout publication and stop-sharing confirmations.
Test narrow windows, both appearances, larger text, keyboard navigation and VoiceOver. These fixtures
supplement the account and transport integration tests; their API deliberately
refuses writes.

The cross-repository transport check uses the real website account handlers,
Team relay, Noise handshake and host dispatch with disposable local accounts:

```sh
cargo build -p tokenstat-host --example team-transport-probe
task_probe="$(pwd)/target/debug/examples/team-transport-probe"
cd ../www
bun scripts/teams-transport-e2e.js "$task_probe"
```

Pass an absolute probe path when running from another directory. The runner
binds random loopback ports and uses an in-memory database and temporary host
directories. It checks scoped reads, renewal, denied personal methods, outsider
access and live repository revocation, then removes its processes and files.

The scheme also has native iOS UI tests. Pass the separate device’s identifier
with `-destination 'platform=iOS Simulator,id=YOUR_QA_DEVICE_ID'` and run `test`
with `-parallel-testing-enabled NO`. Tests check default repository access,
write refusal, device consent, exact invitation access, expiry, larger text and recovery states. Screenshots are
stored as XCTest attachments in the result bundle.

Use `--device-family ipad` for the tablet fixture. The `askUncertain` scenario loses a fictional accepted Ask reply, then requires an exact retry and exposes Stop for that same run. It never launches a host or agent.

For a focused lane regression, pass `--lanes-only` after both binary paths.
This explicitly skips the guardian/lease lifecycle suite and reports a filtered
result; omit the filter for release verification.
`TOKENSTAT_TEAMS_KEEP_FIXTURE=1` retains the disposable fixture and its stderr
logs for diagnosis. Remove that retained directory after inspection.

The `newOrganization` scenario has one member and no projects, to exercise the
first-project setup state. Directory responses include fictional expiring app
presence; they do not infer activity from a running computer. Shared catalog
activity metadata is synthetic and device-local read positions live only in
the fixture app's preferences. Production account menus no longer switch a
Personal/organization scope; navigate between organizations inside Team.
