# Mobile release parity

This is the release gate for customer-visible mobile behavior. A shared feature
does not leave a release branch until its Apple and Android implementations and
contract tests are green. Platform presentation may differ; behavior may not.

| Capability | Rust contract | Apple | Android |
| --- | --- | --- | --- |
| Sign-in, sign-out, account status | built | built | built |
| Account activity, limits, insights | built | built | built |
| Device and remote workspace directory | built | built | built |
| Sessions, changes, tasks, notes | built | built | foundation |
| Workflows, automations, files | built | built | foundation |
| Interactive terminal emulator | built | built | pending terminal-view integration |
| Port-forwarded browser | built | built | pending WebView integration |
| Store subscription activation | Apple + Google built | built | built; service endpoint required |
| Push registration and delivery | built | built | built; FCM configuration required |

`foundation` means the Android screen reaches the real remote method and
renders its result, but its final task-specific editor/actions are not yet the
release-quality equivalent of the Apple screen. These rows block production.
