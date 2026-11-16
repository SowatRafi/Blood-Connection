# Phone, watch and car support

An initiative by Bindubashini Boys’ 2015 & Friends

## What the companion experience means

Blood Connection's complete member experience runs on Android and iOS phones. Administrators can use the phone app or the separate admin website. Watch support uses the paired phone's native notifications; car support hands a chosen public destination to a navigation application. These are real companion integrations, **not standalone Blood Connection watch apps or dedicated Android Auto/CarPlay apps**.

| Platform | Implemented integration | Boundary and verification |
|---|---|---|
| Android phone | Flutter member/admin app, native permissions, location, private messaging/calls and notification presentation | Debug builds can be installed and exercised on the connected Pixel. Production requires configured services and signing. |
| iPhone | Shared Flutter app with native iOS configuration and notification integration | Building, signing and device validation require macOS/Xcode and Apple provisioning. No successful iOS build is claimed from this Windows workspace. |
| Wear OS | Native Android notifications are eligible for paired-watch bridging; opening the phone app is the companion action | Requires a paired watch, enabled notification permissions and a working delivery path on the phone. No independent watch sign-in, search, availability editor or voice call app is included. |
| Apple Watch | Native iPhone notifications are eligible for watch forwarding with the registered open-on-phone action | Requires a paired watch and enabled mirroring. iOS/watchOS choose which device receives an alert. No independent watchOS target or complication is included. |
| Android Auto | External navigation handoff from the phone to an installed compatible maps application | Blood Connection does not register an automotive messaging or navigation service. No direct car-screen donor search or account administration is included. |
| CarPlay | External navigation handoff from the phone to an installed compatible navigation application | Blood Connection has no approved CarPlay entitlement or CarPlay scene. The chosen navigation app supplies the car interface. |

## Watches: private, brief and actionable

Android automatically bridges eligible phone notifications to paired Wear OS watches. Its system notification interface provides an open-on-phone affordance. A separate watch APK is not required for that path. Setting `localOnly: true` would prevent this behavior, so the companion notifications must remain bridgeable. Device settings and the chosen watch companion app still control whether they appear. [Android Wear OS notification documentation](https://developer.android.com/training/wearables/notifications)

Apple forwards eligible local or remote iPhone notifications to an unlocked watch being worn when the phone is not active. An unlocked, active iPhone normally receives the alert instead. Background-only notifications are not forwarded. This means seeing an alert only on the phone during a test is not evidence that watch forwarding is broken. [Apple notification forwarding rules](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding)

Notifications should reveal only that Blood Connection needs attention. Blood type, private measurements, exact location, report evidence and message text should remain inside the authenticated app. The initial watch action opens the phone experience. It must not accept a donation, change availability, approve a ban or answer a voice call without the corresponding authenticated interaction. Apple's notification categories require every registered action to be handled; its watch double-tap gesture can invoke the first nondestructive action. [Apple actionable notification guidance](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types)

Watch forwarding does not create a background-delivery service. Android remote delivery needs an installed UnifiedPush distributor and a reachable configured push endpoint. Apple remote delivery needs APNs configuration and a correctly signed iOS app. Local test notifications prove presentation only. Neither local tests nor foreground polling prove delivery after the phone app is terminated.

## Cars: hand off navigation, keep private workflows on the phone

Choose a public hospital, blood bank or agreed public meeting destination before driving. Opening directions transfers that destination to the selected navigation application. It does not transfer donor search results, donor coordinates, health measurements or account tokens. The selected maps application applies its own location permissions and privacy terms.

Maps links can open a compatible navigation application or fall back to its website; this is not a guarantee that a connected vehicle starts navigation automatically. The driver chooses the supported navigation experience on their vehicle. Google documents its cross-platform URL behavior and URL-encoded destination parameters; Apple documents its Maps URLs separately. [Google Maps URLs](https://developers.google.com/maps/documentation/urls/get-started), [Apple Maps URLs](https://developer.apple.com/documentation/mapkit/unified-map-urls)

The existing in-app chat does not by itself establish Android Auto support. Google's notification-based automotive messaging integration requires `MessagingStyle`, reply and mark-as-read actions, a service that handles those actions, and the automotive manifest declaration. Blood Connection does not claim that integration until all those pieces and car-quality testing exist. [Android Auto messaging requirements](https://developer.android.com/training/cars/communication/notification-messaging)

A direct CarPlay application requires an accepted app category and Apple's entitlement process. Medical donor matching must not be relabeled as a navigation or public-safety app merely to obtain a car icon. Eligible messaging/VoIP functionality would still need the relevant SiriKit/CarPlay implementation, entitlement and review. [Apple CarPlay developer requirements](https://developer.apple.com/carplay/)

## Required device verification

The repository implements companion behavior; actual paired-watch and vehicle compatibility remains a release gate. The connected Pixel alone cannot validate the following:

1. **Wear OS:** pair a watch, enable Blood Connection notifications in the watch companion app, grant phone notification permission, lock the phone, and send a privacy-safe test alert. Verify readable text, the app icon, open-on-phone behavior and dismissal. Repeat with real UnifiedPush delivery while the phone app is backgrounded.
2. **Apple Watch:** build/sign on macOS, install on iPhone, enable mirroring in Watch → Notifications, wear/unlock the watch and lock the iPhone. Verify presentation and the safe action. Repeat with a real APNs notification. Test Focus/Do Not Disturb behavior without promising a delivery bypass.
3. **Android Auto:** while parked, connect a compatible vehicle/head unit or the official test environment. Open the selected public destination on the phone and verify the navigation application's car experience. Do not claim a Blood Connection launcher icon.
4. **CarPlay:** while parked, connect a compatible vehicle/simulator setup and verify the selected maps destination. Apple signing, provisioning and actual hardware remain external requirements.
5. **Privacy/lifecycle:** sign out, revoke notifications, enter the donation cooldown, disable availability, block a peer and ban a fictional test account. Confirm that no prohibited blood-request alerts are delivered and that notifications never expose health or conversation content on the lock screen/watch.

Independent watch applications would be additional product work: secure companion pairing, minimal watch-specific screens, offline/error behavior, account revocation, platform packaging and watch hardware tests. No empty or uncompiled watch/car target is included to imply that work is complete.
