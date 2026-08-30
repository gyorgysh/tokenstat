# Google Play release

Package name: `ai.tokenstat.tokenstat`.

The repository already builds an AAB, signs it when the upload keystore is
present, and the tag workflow uploads that AAB to the internal track. None of
that creates a Play Console account. Google does not expose developer signup,
identity verification, or "create app" over the Android Publisher API. Those
steps are a browser session on [play.google.com/console](https://play.google.com/console).

## What is already wired

- Application id `ai.tokenstat.tokenstat`, `targetSdk` 36.
- Subscription product ids: `ai.tokenstat.supporter.yearly`,
  `ai.tokenstat.patron.yearly`, `ai.tokenstat.legend.yearly`.
  Duration lives on those products as a second base plan (`monthly` on
  Patron and Legend), not as a separate product id. Paywall UI still
  lists yearly. Leave the monthly base plans draft until the client
  picks offers by `basePlanId`.
- Gradle `signingConfigs.play` reads `TOKENSTAT_ANDROID_KEYSTORE` and friends.
- `.github/workflows/release.yml` job `android` publishes to the internal
  track when the `release` environment has the secrets below.
- Preview builds stay debug APKs. They are not Play uploads.

## Local upload key (this machine)

Google holds the **app signing key** (Play App Signing). We hold the
**upload key**. That is the Android equivalent of the Apple Developer ID P12:
local secret, CI copy, never git.

```bash
scripts/android-play-keystore.sh init
scripts/android-play-keystore.sh fingerprints
scripts/android-play-keystore.sh status
scripts/android-play-keystore.sh push-github
```

`init` writes `~/.tokenstat/android/play.jks` and `play.env`. It will not
overwrite an existing keystore. After first Play upload, that certificate is
locked as the upload cert. Losing it means a Play support request to rotate.

Signed local bundle:

```bash
scripts/build-android-release.sh
```

That sources `play.env` and writes `dist/android/tokenstat-<version>-release.aab`.

The `release` GitHub environment needs:

| Secret | Source |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `push-github` |
| `ANDROID_STORE_PASSWORD` | `push-github` |
| `ANDROID_KEY_ALIAS` | `push-github` (`upload`) |
| `ANDROID_KEY_PASSWORD` | `push-github` |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Play Console, after the app exists |

Do not put any of those values in this file or in git.

## Play Console (browser, once)

Use the pueev company Google account (`gyorgy@pueev.com`), not a personal
Gmail. This Mac's `gcloud` is currently a different Google login. Do not
create the Play Cloud project under that login.

1. Open [play.google.com/console](https://play.google.com/console) and pay the
   one-time $25 registration.
2. Register as an **organization**: pueev OÜ. An organization account skips
   the personal-account closed-test quota (12 testers / 14 days). You will
   need a D-U-N-S number, a government ID, the company address, and
   https://tokenstat.ai as the verified site. Identity review can take days.
3. Create the app:
   - App name: `tokenstat`
   - Default language: English (United States)
   - App or game: App
   - Free or paid: Free (subscriptions are in-app)
   - Package name: `ai.tokenstat.tokenstat`
   Let Play check the name. A brand-new package is registered to this
   developer automatically (Android developer verification, 2026). All new
   Play apps use Play App Signing, with Google managing the app signing key.
4. First AAB: Release → Testing → Internal testing → Create new release.
   Upload `dist/android/tokenstat-<version>-release.aab`. When asked about
   app signing, let Google generate the app signing key. Our keystore becomes
   the upload key. Do not export a PEPK zip and do not upload a self-held
   app signing key.
5. After that upload, copy two SHA-256 values from Setup → App signing:
   - **App signing key certificate** (what devices and Firebase see)
   - **Upload key certificate** (must match `scripts/android-play-keystore.sh fingerprints`)

Internal testing is enough to prove the pipeline. Production stays gated on
`PARITY.md`.

Do not sideload more copies of `ai.tokenstat.tokenstat` onto physical phones
until the Play app exists. A package seen on a certified device with the
debug keystore can force a "prove you own this key" step on create-app.

## API access, after the app exists

The tag workflow talks to Play through a service account. Create it on a
Cloud project owned by the same Google account as Play Console.

1. Play Console → Setup → API access → link a Cloud project (create one
   named `tokenstat-play` if none is linked).
2. Enable the Google Play Android Developer API on that project.
3. Create a service account, grant it in Play Console Users and permissions:
   Admin (or Release to production, plus financial if it will read
   subscriptions).
4. Download the JSON key. Set it as `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` on
   the GitHub `release` environment (the whole file, as the secret value).
5. Enable Real-time developer notifications on that same Cloud project
   (Pub/Sub topic the account service will subscribe to). Needed for Play
   Billing, not for the first internal AAB.

The Android Publisher API can then upload AABs, manage tracks, and create
the subscription products. It cannot create the developer account or the
first app.

## Subscription products

Create these auto-renewing subscriptions, same ids the Android client
already queries:

- `ai.tokenstat.supporter.yearly` — yearly base plan only
- `ai.tokenstat.patron.yearly` — yearly base plan `annual`, plus a
  monthly base plan `monthly` (draft until the paywall can pick it)
- `ai.tokenstat.legend.yearly` — same shape as Patron

Base plans should match the Apple / Paddle prices. Activate yearly on
the internal track first, then production. Do not create separate
`…patron.monthly` / `…legend.monthly` products. Trial stays an offer
on the yearly base plan (`trial-3d`), not a way to sell monthly.

The account service must implement `POST /api/v1/billing/google/activate`,
verify the package, product and purchase token with the Play Developer API,
acknowledge initial purchases, and consume Real-time Developer Notifications.
It must return the same account billing shape as `/api/v1/me`, with
`provider: "google_play"`. That endpoint lives in the website repo, not here.

## Firebase

Firebase must contain an Android app with package `ai.tokenstat.tokenstat`.
Add the **app signing** SHA-1 and SHA-256 from Play Console, plus the debug
keystore fingerprints if you want push on sideload builds. Put the downloaded
`google-services.json` in `apps/android/app/` for local or CI release builds.
The file is gitignored. The push service must accept `platform: "android"`
and deliver those registrations through FCM.

## Store listing (before production, not for internal testing)

- Privacy policy: https://tokenstat.ai/privacy
- Account deletion: https://tokenstat.ai/settings/data
- Contact: gyorgy@pueev.com
- Data safety wording must match the Apple disclosure: aggregate token
  counts, model/source names and timestamps can sync to the account.
  Prompts, responses, file contents and local paths do not enter the
  aggregate archive.
- Content rating questionnaire, target audience, ads declaration (no ads).
- Phone and tablet screenshots.
- Store graphics in `apps/android/store/`. Regenerate with
  `NODE_PATH=../www/node_modules node scripts/generate-play-icon.js`.

  | File | Use |
  | --- | --- |
  | `play-icon-512.png` | Play app icon. 512×512, 32-bit PNG, full square. |
  | `play-icon-mono-white-512.png` | iOS light: colour bars on `#fbfbfd` paper. |
  | `play-icon-mono-black-512.png` | iOS dark: colour bars on `#171722` paper. |
  | `play-feature-graphic.png` | Feature graphic. 1024×500, 24-bit PNG, no alpha. House paper, bars centred, no type. |

  Play applies a 30% corner-radius mask to the icons. Do not bake rounded
  corners or an outer shadow into any of the 512 files. The listing uses the
  colour icon. Light and dark keep the same bar colours as the iOS app icon.

Promote off the internal track only after the parity gate in `PARITY.md`,
license tests, billing license tests, and FCM tests are complete.

## App Links

The manifest already auto-verifies `https://tokenstat.ai/app/auth`. After
Play App Signing is enrolled, publish
`https://tokenstat.ai/.well-known/assetlinks.json` with the **app signing**
SHA-256 (Play's key, not the upload key).
