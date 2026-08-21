# Google Play release

Create and reserve the Play application as `ai.tokenstat.tokenstat`. Enable Play
App Signing, then create these yearly subscription products:

- `ai.tokenstat.supporter.yearly`
- `ai.tokenstat.patron.yearly`
- `ai.tokenstat.legend.yearly`

The account service must implement
`POST /api/v1/billing/google/activate`, verify the package, product and purchase
token with the Google Play Developer API, acknowledge initial purchases, and
consume Real-time Developer Notifications. It must return the same account
billing shape as `/api/v1/me`, with `provider: "google_play"`.

Firebase must contain an Android app with the same package. Put the downloaded
`google-services.json` in `apps/android/app/` for local or CI release builds;
the file is intentionally ignored. The push service must accept
`platform: "android"` and deliver those registrations through FCM.

The `release` GitHub environment accepts:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_STORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`
- `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`

The tag workflow uploads to the internal track. Promote only after the parity
gate in `PARITY.md`, license tests, phone/tablet screenshots, Data Safety form,
content rating, privacy policy, account-deletion URL, billing license tests,
and FCM tests are complete.

Data Safety wording must match the existing Apple disclosure: aggregate token
counts, model/source names and timestamps can sync to the account; prompts,
responses, file contents and local paths do not enter the aggregate archive.
