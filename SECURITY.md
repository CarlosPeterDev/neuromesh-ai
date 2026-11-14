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
