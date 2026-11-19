# Security

Report vulnerabilities privately through GitHub's "Report a vulnerability" (Security tab). Do not post exploit details in public issues.

## Release signing

CI signs release builds only when these repository secrets exist (Settings → Secrets and variables → Actions):

- `ANDROID_KEYSTORE_BASE64` — base64 of your `.jks` file
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Create a key once with (`keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias neuromesh`), then `base64 -w0 release.jks`. **Back the keystore up safely: Google Play updates require the same key forever.**

Without these secrets CI produces *development-signed* builds, published as pre-releases and named accordingly. Do not distribute them as production releases.


## Developer diagnostic delivery

The report screen previews the exact diagnostic report before the user sends it.
Developer delivery is configured in GitHub Actions secrets, never by asking app
users to enter credentials. For direct delivery, set `NEUROMESH_REPORT_BOT_TOKEN`
and `NEUROMESH_REPORT_CHAT_ID`. Builds pass these through a temporary private
Flutter define file; the repository and public build logs must not contain the
values. Derived base64 compiler arguments are masked as well.

Direct client delivery embeds its credential in distributed application binaries;
it cannot keep a bot token secret from someone analysing those binaries. Use a
server-side `NEUROMESH_REPORT_ENDPOINT` when the token must remain outside clients.
The report button always describes an upload and lets the user review its content.
