# Publishing to Google Play (checklist)

Everything here is free except the one-time Play developer registration fee.

1. **Release signing.** Create an upload keystore and add the four repo secrets described in SECURITY.md. The workflow then produces a properly signed APK and AAB instead of a dev-signed pre-release. Keep the keystore backed up: losing it means you cannot update the app.
2. **Upload the AAB** (`NeuroMesh-AI-*.aab` from the release) to a Play Console internal-testing track first.
3. **Privacy policy URL.** Host PRIVACY.md (for example via GitHub Pages or the raw repo page) and paste the URL.
4. **Data safety form.** Declare: no data collected by the developer; data stays on device; microphone used for features, processed on device; network used to download models. Answer according to the final build.
5. **Content rating and target audience.** Complete the questionnaire. The app is a general-purpose AI chat tool and can generate unfiltered model output, so state that clearly in the store listing.
6. **App access / permissions declarations.** Foreground service (data sync / media processing) and microphone need a short justification.
7. **Store listing.** Name, short description, full description, 512x512 icon, feature graphic, at least 2 phone screenshots.
8. **Target API level and 64-bit.** The build already targets a recent API and ships arm64.
9. **AdMob (optional).** Not included. If you add ads, update the privacy policy and the Data safety form, and consider whether ads fit a privacy-first app.
