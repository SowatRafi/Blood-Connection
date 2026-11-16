# Open-source components and service boundaries

An initiative by Bindubashini Boys’ 2015 & Friends

## Source ownership and license scope

The application, admin UI and backend source are maintained in this repository. A first-party reuse license has **not yet been selected**; that is a separate owner decision from using open-source development tools. An attribution string alone is not a software license. Third-party packages retain their own licenses and notices; do not replace those notices with the project's community credit.

Open-source application code does not mean every mobile operating system, identity provider, store or hosted service it interoperates with is open source. The goal is self-hostable application infrastructure and inspectable source, with proprietary platform/service boundaries explicitly identified below.

The selected logo originated from a one-time image-generation service during design. The application bundles the user-selected PNG locally and has no runtime image-generation dependency. Platform icon packaging uses the existing open-source CairoSVG tooling. Artwork provenance and the original prompt are recorded in [the brand notes](../design-system/brand/README.md).

## Direct dependency inventory

Flutter versions/licenses below were inspected from the resolved package cache on 15 November 2026. JavaScript backend versions/licenses were inspected from `backend/package-lock.json` on 16 November 2026; Node and PostgreSQL/PostGIS versions were checked against the installed runtime/container. `mobile/pubspec.lock` and `backend/package-lock.json` record exact dependency resolution. This is a direct-dependency inventory, not a claim that every transitive binary or optional SDK has undergone a complete license audit.

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
| Node.js | 24.22.3 locally; 24 LTS line in CI | MIT plus bundled third-party notices; JavaScript runtime, HTTP/2, fetch and crypto |
| Fastify | 5.12.8 | MIT; API routing, JSON-schema validation and request lifecycle |
| `@fastify/cors` | 11.4.3 | MIT; explicit browser-origin policy |
| `@fastify/helmet` | 13.2.0 | MIT; response security headers |
| `@fastify/static` | 10.1.11 | MIT; local admin assets |
| `@fastify/swagger` | 9.9.4 | MIT; generated API schema |
| `pg` | 8.23.1 | MIT; parameterized PostgreSQL client and connection pool |
| `jose` | 6.2.17 | MIT; ES256 APNs and HS256 short-lived room signatures |
| `sharp` | 0.35.5 | Apache-2.0; bounded image decoding and metadata-free JPEG output; native dependencies have separate notices |
| `web-push` | 4.0.0 | MPL-2.0; RFC 8291 notification encryption |
| `http_ece` | 1.2.1 | MIT; direct development dependency for independent payload-decryption checks; also used transitively by web-push |
| PostgreSQL | 18.7 | PostgreSQL License; transactional registry and country-schema storage |
| PostGIS | 3.7.0 | GPL-2.0-or-later; indexed geography/radius queries |
| LiveKit server | 1.13.11, pinned image digest | Apache-2.0; optional self-hosted voice transport |
| Python `livekit` | 1.2.1 | Apache-2.0; optional synthetic audio test client against the JavaScript API, not backend runtime |
| CairoSVG | 2.9.0 | LGPL-3.0-or-later; optional development-only platform-icon rendering |

Upstream primary notices include [Fastify's MIT license](https://github.com/fastify/fastify/blob/main/LICENSE), [web-push's MPL notice](https://github.com/web-push-libs/web-push/blob/master/LICENSE), [PostgreSQL's license](https://www.postgresql.org/about/licence/), [PostGIS's licensing inventory](https://github.com/postgis/postgis/blob/master/LICENSE.TXT), [Supabase Flutter's MIT license](https://github.com/supabase/supabase-flutter/blob/main/LICENSE), [LiveKit Flutter's Apache-2.0 project](https://github.com/livekit/client-sdk-flutter), and the [notification plugin's BSD notice](https://github.com/MaikuB/flutter_local_notifications/blob/master/flutter_local_notifications/LICENSE). Preserve applicable notices when distributing source or binaries; dependency licenses are not all MIT.

The backend no longer runs Python, FastAPI or SQLite. ISO country names come from Node's bundled ICU via `Intl.DisplayNames`, with a fixed country-code allowlist for schema identifiers. The one-time legacy-data importer uses Node's built-in SQLite reader only to read old local files into PostgreSQL; it is not an API storage engine. Python remains optional for artwork regeneration with CairoSVG and the standalone synthetic-audio SDK probe. Neither is needed to run the application API or backend test suite.

Manrope comes from the [official Google Fonts Manrope source](https://github.com/google/fonts/tree/main/ofl/manrope). Its copyright and SIL Open Font License 1.1 are preserved with the bundled font (`admin/assets/OFL.txt` and the corresponding mobile font assets). The admin stylesheet loads `admin/assets/Manrope.ttf` locally; no Google Fonts network request is needed at runtime.

The Android `geolocator_android` 5.2.1 package currently declares `com.google.android.gms:play-services-location:21.2.0`. Its Dart wrapper being MIT does not make Google Play services open source. Selecting Android LocationManager at runtime does not remove that compiled dependency. A strictly Google-free Android dependency graph requires replacing or changing that platform implementation and revalidating location behavior; the current inventory does not claim that graph is wholly open source.

## Self-hostable infrastructure

- **API and storage:** Node.js, Fastify, PostgreSQL and PostGIS run locally without a paid cloud account. The accepted local design uses one PostgreSQL database with separate country schemas and a shared safety registry. Serializable transactions preserve cross-country safety changes; a separate migration role provisions schemas while the API uses a restricted runtime role. Schemas are logical separation, not physical country residency. Production deployment, TLS, encrypted backups, restoration and capacity remain operator responsibilities.
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

Regenerate the resolved dependency inventory for every release, preserve package notices, include Flutter's license display in the distributed app, and review native/transitive binaries as well as Dart/npm packages and container images. Use the committed npm lockfile with `npm ci`, check advisories with `npm audit`, and rerun the relevant tests before dependency upgrades; a clean advisory scan is not a security guarantee. Keep SDK keys, database credentials and signing files outside Git. The project does not grant permission to republish third-party trademarks or to imply official school, platform or map-provider endorsement.
