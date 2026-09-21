# Privacy baseline

Last updated September 21, 2026

RoamPi is under development. This document records the privacy constraints for implementation and App Store disclosure. The current demo app does not connect to a network, collect analytics, show advertising, sell subscriptions, or transmit user data.

## SSH credentials

Future releases will create or import SSH credentials only after user action. Private keys and app credentials must remain in Apple Keychain. RoamPi must not write private keys, passwords, tokens, or key material to logs, analytics, app state restoration, crash metadata, diagnostics, or exported profiles.

## Remote content

Remote terminal output, commands, project paths, hostnames, usernames, Pi conversations, and files may contain sensitive information. RoamPi will process this content to provide the requested remote session. It must not collect or transmit remote content to HemSoft. Provider credentials stay on the selected remote host.

## Advertising

The planned free tier is ad-supported. Advertising is not implemented. Before ads ship, RoamPi must document the selected provider, data collected, tracking behavior, age-rating impact, consent flow, and a way to use the paid plan without ads. App Tracking Transparency permission will be requested if Apple's rules require it. RoamPi must not send SSH credentials or remote content to an advertising provider.

## StoreKit and RoamPi Pro

The planned RoamPi Pro subscription costs $19 per year. StoreKit is not implemented. Apple will process purchases and subscription status. RoamPi should retain only the entitlement information needed to unlock paid features and must disclose any server-side receipt processing before release.

## Apple crash reports and MetricKit

Apple may provide opt-in crash reports and MetricKit performance diagnostics under the user's device and developer-sharing settings. Before enabling collection, RoamPi must redact usernames, hostnames, commands, project paths, tokens, terminal content, and remote output. Diagnostics must use generated identifiers rather than saved host or session names.

## User-submitted diagnostics

A future diagnostic export must require an explicit user action and show what will be shared before submission. The export must exclude secrets and remote content by default. Users must be able to cancel and inspect or delete the package before sending it.

## Data retention and deletion

The current demo stores no user data. Future connection profiles and preferences should remain on device unless a separate synchronization design is approved and disclosed. Removing a profile must remove its app-owned metadata and Keychain references without changing the remote host.

## Contact and changes

Privacy answers and contact details must be finalized before TestFlight external testing. Material changes will update this file, the App Store privacy answers, and the changelog together.
