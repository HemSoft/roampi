# App Store release tracker

## Product identity

| Item | Decision |
| --- | --- |
| App name | RoamPi |
| Bundle identifier | `com.hemsoft.RoamPi` |
| Minimum OS | iOS and iPadOS 17.0 |
| Distribution | iPhone and iPad through the App Store |
| Free plan | Ad-supported, details must pass privacy review before implementation |
| RoamPi Pro | $19 per year through StoreKit |
| License | MIT |

## Guideline assessment

RoamPi's core connection path is standard SSH to a user-authorized macOS or Linux host. It accepts ordinary DNS names and IP addresses and does not require another iOS app. Tailscale is optional routing supplied by the separately installed Tailscale app.

Remote commands, Pi, tmux, and provider integrations execute on the user's host. RoamPi does not download or execute remote code on iOS. The native screens are fixed app functionality backed by bounded SSH and RPC protocols, and the terminal remains a general interface to the user's computer. Release review notes must state these boundaries and provide a network-free demo.

## TestFlight

- [ ] Create the App Store Connect app record.
- [ ] Add distribution signing and an App Store provisioning profile outside source control.
- [ ] Archive a release build with no personal signing data in the project.
- [ ] Upload the build and confirm processing.
- [ ] Complete internal TestFlight testing on a physical iPhone and iPad.
- [ ] Test demo mode without a tailnet, host, or credentials.
- [ ] Add beta review contact details and notes before external testing.
- [ ] Record tester feedback and resolved regressions in the changelog.

## Screenshots and listing

- [ ] Capture current release-candidate screenshots for supported iPhone display sizes.
- [ ] Capture current release-candidate screenshots for supported iPad display sizes.
- [ ] Include compact and regular dashboard layouts in light and dark appearance.
- [ ] Use only fictional demo data. No hostnames, usernames, project paths, tokens, terminal output, or personal information.
- [ ] Write the subtitle, description, keywords, support URL, marketing URL, and copyright.
- [ ] Confirm screenshots and listing claims match the submitted build.

## Privacy answers

- [ ] Reconcile every App Store privacy answer with `PRIVACY.md` and the release-candidate implementation.
- [ ] Record SSH credential storage and confirm private keys remain in Keychain.
- [ ] Record how remote content is processed and confirm HemSoft does not collect it.
- [ ] Document the advertising provider, collected data, tracking behavior, and consent flow before the free plan shows ads.
- [ ] Document StoreKit purchase and entitlement data for the $19 yearly RoamPi Pro plan.
- [ ] Document Apple crash reports and MetricKit collection, redaction, and retention.
- [ ] Document the explicit preview and consent flow for user-submitted diagnostics.
- [ ] Publish a support contact and public privacy-policy URL.

## Review notes

- [ ] Explain that RoamPi runs user-requested commands only on machines the user has authorized.
- [ ] Explain that standard SSH works without Tailscale and that the separately installed Tailscale app is an optional private network route.
- [ ] Provide exact steps to launch deterministic demo mode without a private tailnet.
- [ ] Provide a disposable review host if Apple asks to inspect remote-session behavior.
- [ ] Describe standard SSH, host-key verification, tmux persistence, and Pi authentication once implemented.
- [ ] State that provider credentials remain on the remote host.
- [ ] Describe the free ad-supported plan and $19 yearly RoamPi Pro plan as implemented in the submitted build.

## Release-candidate checks

- [ ] Freeze the release candidate and record its commit SHA and version.
- [ ] Build and test the exact archive commit on the documented Xcode version.
- [ ] Run unit tests, UI tests, formatting, and dependency audit.
- [ ] Validate on the minimum iOS and iPadOS 17.0 versions and the latest public versions.
- [ ] Validate Dynamic Type, VoiceOver, keyboard navigation, light and dark appearance, iPad multitasking, and rotation.
- [ ] Test install, upgrade, subscription purchase, restore, expiration, ads, and offline behavior when those features exist.
- [ ] Confirm logs, crash reports, MetricKit payloads, and submitted diagnostics contain no secrets or remote content.
- [ ] Confirm the changelog, privacy document, App Store answers, screenshots, and review notes match the build.
- [ ] Tag the release only after App Store approval and record its release date.
