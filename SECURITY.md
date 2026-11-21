# Security

Report vulnerabilities privately through GitHub's "Report a vulnerability" (Security tab). Do not post exploit details in public issues.

## Release signing

CI signs release builds only when these repository secrets exist (Settings → Secrets and variables → Actions):

- `ANDROID_KEYSTORE_BASE64` — base64 of your `.jks` file
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Create a key once with (`keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias neuromesh`), then `base64 -w0 release.jks`. **Back the keystore up safely: Google Play updates require the same key forever.**

Without these secrets CI labels the versioned GitHub Release **Development build** and gives the Play AAB a `-dev` suffix. GitHub can mark that release **Latest** for repository downloads. Use the production upload key for a Play release.


### Persistent GitHub APK updates

Use a dedicated, backed-up keystore for GitHub APKs. Set these repository Actions secrets as a group:

- `ANDROID_UPDATE_KEYSTORE_BASE64`
- `ANDROID_UPDATE_KEYSTORE_PASSWORD`
- `ANDROID_UPDATE_KEY_ALIAS`
- `ANDROID_UPDATE_KEY_PASSWORD`

Set the repository Actions variable `ANDROID_UPDATE_CERT_SHA256` to the signing certificate's 64-character hexadecimal SHA-256 digest, without separators. CI checks both APKs against it. Keep the same signer for subsequent GitHub APKs. The Play bundle continues to use its own signing settings.

### Public test APKs

When no private GitHub APK signer is configured, CI signs the standalone APKs with the reusable public test certificate and builds them as **NeuroMesh AI Test** (`com.neuromesh.ai.test`). Android can update one Test version over another and keep the Test app's data. The original `com.neuromesh.ai` app can stay installed alongside it. To move chats and settings from an older build, export a JSON backup under **Settings → Toolbox → Data & support** and restore it in Test.

The test signer uses a pinned public AOSP apksig fixture and the project's public test certificate. Anyone can sign a Test APK. Use it for disposable testing and install it from this repository's releases. The Play AAB keeps the normal application ID and a separate upload signer. Adding Play credentials leaves the GitHub Test signer in use until you configure a private GitHub APK signer. Keep Play and privately distributed signing credentials backed up. [Public fixture source](https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/test/resources/com/android/apksig/rsa-2048_3.pk8)

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
