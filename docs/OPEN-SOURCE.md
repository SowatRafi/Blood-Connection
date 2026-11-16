# Open-source components and service boundaries

An initiative by Bindubashini Boys’ 2015 & Friends

## Source ownership and license scope

The application, admin UI and backend source are maintained in this repository. A first-party reuse license has **not yet been selected**; that is a separate owner decision from using open-source development tools. An attribution string alone is not a software license. Third-party packages retain their own licenses and notices; do not replace those notices with the project's community credit.

Open-source application code does not mean every mobile operating system, identity provider, store or hosted service it interoperates with is open source. The goal is self-hostable application infrastructure and inspectable source, with proprietary platform/service boundaries explicitly identified below.

The selected logo originated from a one-time image-generation service during design. The application bundles the user-selected PNG locally and has no runtime image-generation dependency. Platform icon packaging uses the existing open-source CairoSVG tooling. Artwork provenance and the original prompt are recorded in [the brand notes](../design-system/brand/README.md).

## Direct dependency inventory

The following versions/licenses were inspected from the resolved Flutter package cache or installed Python package metadata on 15 November 2026. `mobile/pubspec.lock` records exact Dart resolution; backend versions are pinned in `backend/requirements.txt`. This is a direct-dependency inventory, not a claim that every transitive binary or optional SDK has undergone a complete license audit.

| Component | Inspected version | License / role |
|---|---|---|
| Flutter framework | 3.44.2 | BSD-3-Clause; cross-platform UI |
| Manrope variable font | Bundled weight range 200–800 | SIL Open Font License 1.1; local mobile/admin typography |
| Dart `http` | 1.6.0 | BSD-3-Clause; API networking |
| `supabase_flutter` | 2.18.3 | MIT; social-auth client |
| `livekit_client` | 2.13.2 | Apache-2.0; audio-room client |
| `geolocator` | 14.1.2 | MIT wrapper; native location, with Android caveat below |
| `geocoding` | 5.0.1 | MIT wrapper; native geocoding |
| `flutter_secure_storage` | 11.2.0 | BSD-3-Clause; platform-backed token storage |
| `image_picker` | 1.2.4 | BSD-3-Clause; native photo selection |
| `flutter_map` | 8.3.2 | BSD-3-Clause; map rendering |
| `latlong2` | 0.10.1 | Apache-2.0; coordinate helpers |
| `url_launcher` | 6.3.3 | BSD-3-Clause; external navigation handoff |
| `unifiedpush_android` | 3.5.0 | Apache-2.0; official Android push connector, without unused desktop implementations |
| `flutter_local_notifications` | 22.0.1 | BSD-3-Clause; native notification presentation |
| FastAPI | 0.141.1 | MIT; API framework |
| Starlette | 1.6.0 | BSD-3-Clause; HTTP/ASGI layer |
| Uvicorn | 0.52.4 | BSD-3-Clause; local API server |
| HTTPX | 0.28.1 | BSD-3-Clause; server-side HTTP |
| pycountry | 24.6.1 | LGPL-2.1-only; ISO country data wrapper |
| PyJWT | 2.13.0 | MIT; short-lived media credentials |
| Pillow | 13.0.0 | MIT-CMU; validated profile photo decoding/re-encoding |
| pywebpush | 2.5.0 | MPL-2.0; standards-based push payload encryption |
| cryptography | 49.0.0 | Apache-2.0 OR BSD-3-Clause; push encryption/key validation |
| `h2` | 4.4.1 | MIT; HTTPX HTTP/2 extra used for APNs |
| LiveKit server | 1.13.11, pinned image digest | Apache-2.0; optional self-hosted voice transport |
| Python `livekit` | 1.2.1 | Apache-2.0; optional synthetic media test, not the backend runtime |

Upstream primary notices include [Supabase Flutter's MIT license](https://github.com/supabase/supabase-flutter/blob/main/LICENSE), [LiveKit Flutter's Apache-2.0 project](https://github.com/livekit/client-sdk-flutter), [notification plugin's BSD notice](https://github.com/MaikuB/flutter_local_notifications/blob/master/flutter_local_notifications/LICENSE), and [pycountry's LGPL license](https://github.com/pycountry/pycountry/blob/main/LICENSE.txt). Preserve each applicable license and copyright notice when distributing source/binaries. pycountry is not an MIT dependency.

Manrope comes from the [official Google Fonts Manrope source](https://github.com/google/fonts/tree/main/ofl/manrope). Its copyright and SIL Open Font License 1.1 are preserved with the bundled font (`admin/assets/OFL.txt` and the corresponding mobile font assets). The admin stylesheet loads `admin/assets/Manrope.ttf` locally; no Google Fonts network request is needed at runtime.

The Android `geolocator_android` 5.2.1 package currently declares `com.google.android.gms:play-services-location:21.2.0`. Its Dart wrapper being MIT does not make Google Play services open source. Selecting Android LocationManager at runtime does not remove that compiled dependency. A strictly Google-free Android dependency graph requires replacing or changing that platform implementation and revalidating location behavior; the current inventory does not claim that graph is wholly open source.

## Self-hostable infrastructure

- **API and storage:** FastAPI and SQLite run locally without a paid cloud account. Country separation is implemented in the backend; production residency, deployment, encryption/backups and capacity remain operator responsibilities.
- **Identity gateway:** the Supabase client is open source and the gateway can be self-hosted. Google, Apple and Facebook identities remain services operated by those companies. Self-hosting the gateway does not replace their developer registration or OAuth setup.
- **Voice:** the optional local LiveKit server and the client are open source. A managed LiveKit account is not required to run the local call check. Production media hosting, TLS, relay/NAT traversal, bandwidth and monitoring still need infrastructure.
- **Android push:** UnifiedPush allows a compatible distributor/provider to be chosen, including self-hosted infrastructure. A distributor must be installed and configured on the phone; the open protocol does not deliver messages without one. Google/Firebase push is not required for this chosen Android delivery path. [UnifiedPush architecture and distributors](https://unifiedpush.org/)
- **Maps:** the map renderer is open source. OpenStreetMap data, rendered tiles and a hosted tile service are separate things. Attribution must remain visible. Public OSM tiles are best-effort community infrastructure with usage restrictions, not an unlimited production backend. Configure an appropriate provider or self-host tiles before substantial worldwide usage. [OpenStreetMap tile policy](https://operations.osmfoundation.org/policies/tiles/)

## Unavoidable or optional proprietary boundaries

| Boundary | What remains outside the open-source application |
|---|---|
| Apple platforms | iOS/watchOS/CarPlay, Xcode signing/provisioning and App Store review are controlled by Apple. |
| Apple remote push | Native remote notification delivery uses APNs. The provider-side sender can be open source/self-hosted; Apple's delivery network cannot be replaced by a self-hosted APNs server. [Apple remote-notification architecture](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server) |
| Social sign-in | Google, Apple and Facebook accounts/services are required by the selected sign-in policy. The project does not collect a local password as an alternative. |
| Android location | The currently resolved geolocator Android dependency includes Google Play services, as noted above. Native geocoding may use the device vendor's service. |
| External navigation | Google Maps, Apple Maps or another installed navigation app is a user-selected handoff destination, not the application's own route engine. Its service/privacy/license terms apply. |
| Vehicles | Android Auto/CarPlay interfaces, supported app categories, review and entitlement decisions remain platform-controlled. |
| Development tools | Docker Desktop and Xcode are development/distribution tools with their own terms. They are not relicensed by this repository. An open-source container engine can run the Linux server configuration instead of Docker Desktop. |

## Cost is separate from source availability

The local build can use the existing computer, phone and self-hosted services without purchasing an application SaaS subscription. That does not make a worldwide service cost-free. Servers, media bandwidth, push infrastructure, map hosting, monitoring, backups, domains, support and platform developer/store requirements can create operating costs. Managed offerings are optional where the corresponding service can be self-hosted. No pricing, free-tier durability or store approval is promised here.

## Release checks

Regenerate the resolved dependency inventory for every release, preserve package notices, include Flutter's license display in the distributed app, and review native/transitive binaries as well as Dart packages. Keep SDK keys and signing files outside Git. The project does not grant permission to republish third-party trademarks or to imply official school, platform or map-provider endorsement.
