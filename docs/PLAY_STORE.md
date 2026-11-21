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

## Bundle size

The release workflow verifies that the signed AAB is smaller than 200,000,000 bytes and separately measures the ARM64 download after Play splits the bundle. The bundle retains ARM64, ARMv7 and x86-64. Android release packaging omits native debug metadata and two browser-only voice payloads. Native Android voice libraries and phoneme data remain part of the bundle. The workflow uses Flutter to configure the project and Gradle to package the AAB. It then checks the packaged Flutter ELF binaries directly because Flutter 3.38 expects symbol metadata in the upload file.

The Play bundle excludes the optional standalone PRoot launcher. Its runtime check also disables Alpine installation and Android OpenCode. The GitHub standalone APK can offer the Alpine and OpenCode downloads with user consent. Keeping these executables outside the Play upload is a distribution decision. [Android OpenCode preview](OPENCODE.md#android-20-standalone-preview) · [Google Play's executable-code policy](https://support.google.com/googleplay/android-developer/answer/9888379)

On-device OpenCode is part of Android feature parity. Both packages must allow normal local-model chat on first install. Linux and OpenCode are separate from that initial install and download only after the user chooses to install them in Agents. A Play build with parity needs Play-delivered executable components and an ARM64 device test of local-model chat and terminal sessions. Play Feature Delivery can deliver packaged native components on demand. Those components still occupy space in the uploaded AAB. Play Asset Delivery excludes executable code. The project's 200,000,000-byte AAB budget applies to the raw upload file. Google Play's size checks use compressed downloads. [Play Feature Delivery](https://developer.android.com/guide/playcore/feature-delivery) · [Play Asset Delivery](https://developer.android.com/guide/app-bundle/asset-delivery) · [Play size limits](https://support.google.com/googleplay/android-developer/answer/9859372)

The verified v1.0.150 AAB is 186,667,730 bytes across three ABIs. Adding the official 78,461,019-byte OpenCode ARM64 Linux archive gives a rough payload estimate of 265.13 MB before Alpine, terminal tools, or packaging overhead. An ARM64-only estimate is 184.59 MB before those extras, based on subtracting 80.53 MB of compressed ARMv7 and x86-64 libraries from the measured bundle. The estimate does not establish that Linux OpenCode can run from a Play-delivered split or that the runtime fits with all supported ABIs. [Measured bundle](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44851432639) · [OpenCode release assets](https://github.com/anomalyco/opencode/releases/tag/v1.19.6) · [Android tracking issue](https://github.com/CarlosPeterDev/neuromesh-ai/issues/60)

For a packaging check, run **Android release** from GitHub Actions with **Build and verify a development-signed Play AAB artifact** enabled. The workflow uploads the verified bundle to the run without publishing a GitHub Release or using the production signing key. A locally built bundle can be checked with `python scripts/check_play_bundle.py build/app/outputs/bundle/release/app-release.aab`.

Enable **Test Android and desktop packages with development signing and upload them to Actions** to build all current packages together. This preview also checks startup from the universal APK and from Play-style split APKs on the Android emulator. The APKs, AAB, and Android checksum manifest are separate workflow artifacts.
