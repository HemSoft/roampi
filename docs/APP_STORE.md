# App Store decisions

This document records release boundaries. GitHub Issues own the work and its completion evidence; do not add a second release checklist here.

| Item | Decision |
| --- | --- |
| App name | RoamPi |
| Bundle identifier | `com.hemsoft.RoamPi` |
| Minimum OS | iOS and iPadOS 17.0 |
| Distribution | iPhone and iPad through the App Store |
| License | MIT |
| Free plan and Pro | An ad-supported free plan and $19/year StoreKit Pro are proposals, not shipped commitments. [#33](https://github.com/HemSoft/roampi/issues/33) must settle the feature, consent, and privacy boundaries before either is claimed in a listing. |

## Review boundaries

RoamPi uses standard SSH to user-authorized macOS and Linux hosts over any reachable route. The separately installed Tailscale app is optional. Pi, tmux, provider integrations, and user-approved remote commands run on the host. The iOS app does not download executable UI code or install remote software as a side effect of connecting. Native screens are fixed app functionality backed by bounded SSH and RPC protocols; a network-free fictional demo must remain available to reviewers.

Private SSH keys remain in Keychain, Pi provider credentials remain on the host, and listings or screenshots must never reveal personal host details, paths, commands, terminal output, or credentials. An App Store submission must describe actual data collection and features in the submitted build, not planned ads, subscriptions, or onboarding. Tag a release only after App Store approval.

## Issue owners

[Internal TestFlight distribution is #31](https://github.com/HemSoft/roampi/issues/31). [Privacy policy, setup help, listing, and review notes are #32](https://github.com/HemSoft/roampi/issues/32). [The free/Pro decision and any implementation are #33](https://github.com/HemSoft/roampi/issues/33). [Exact-archive release validation and first submission are #37](https://github.com/HemSoft/roampi/issues/37). Security and mobile-device failure testing belong to [#28](https://github.com/HemSoft/roampi/issues/28) and [#29](https://github.com/HemSoft/roampi/issues/29). Use those issues for checklists and status; reconcile each claim with [PRIVACY.md](../PRIVACY.md) and the actual release candidate.
