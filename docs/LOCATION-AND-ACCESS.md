# Location, access and community identity

## Who uses which surface

Members use the Android or iOS mobile app. Administrators have a dedicated workspace in the mobile app and the admin website. The Flutter browser entry point is also admin-only; it does not offer the donor/seeker experience. Server-side role checks protect moderation data and actions. Public sign-in configuration is not a grant of administrative access.

Browser-origin member requests are rejected by the API, in addition to the UI gate. Browser headers are not device attestation: a custom HTTP client can omit them. Before requiring cryptographic proof of an authentic native installation, configure Android Play Integrity and Apple App Attest with server verification. Ordinary users are given no member website or browser member login flow.

## Automatic location

Automatic mode is the default for real mobile accounts. Explain location use before requesting the operating system's permission. The app obtains a foreground position and uses the platform geocoder to resolve its ISO country and local area. The country, area and coordinates travel as one update to the API. No phone locale, SIM, IP address or time-zone guess is treated as a verified physical location.

Refresh when the member opens or returns to the app, and before searching when the last check is stale. Throttle repeated checks to avoid battery drain. A country change moves the active profile into the destination country schema in PostgreSQL, while donation recovery dates, voluntary availability, blocking and account bans remain intact. This also works for a new, incomplete profile. Precise coordinates are never exposed in donor results.

Location updates do not run while the app is closed. Permission denial, disabled GPS, geocoder failure, or an unsupported destination must be visible. Do not quietly search the previous country after a failed refresh: offer Retry and Choose location. A stale account header cannot prevent recovery of the account's current region.

## Manual choice

The member chooses a country and types an area or city. Resolve that place to coordinates, then check that the resolved country matches the selected country before saving. Never combine a new country label with old coordinates. Manual mode remains selected until the member chooses automatic mode again, so a deliberate location choice is not immediately overwritten by GPS.

Manual entry is a fallback for permission denial as well as a deliberate override. It does not require people to know latitude or longitude. Forward/reverse geocoding depend on the platform's service and network availability. A failed or ambiguous lookup must not silently save a guessed location.

## Data and consent

The one-time automatic-location explanation covers updating the discovery country while travelling. The operating system controls location permission separately. No background location permission, contact access, or phone-number field is added. Platform geocoding may process location or place queries through Google/Apple services; include that processing in the final privacy notice. API coordinates are inputs used for matching, not proof against GPS spoofing.

Local demos retain their fictional location until automatic detection is explicitly selected, preventing a sample account from unexpectedly collecting the owner's position.

The local layout is one PostgreSQL database with a registry and isolated country schemas, as approved for this migration. Moving the profile/photo and global active-country state uses one serializable database transaction; a failed move rolls back. This does not claim separate national databases or geographic data residency. Country schemas must be provisioned before use; request-time selection cannot create arbitrary schemas.

## Brand signature

Primary signature: **An initiative by Bindubashini Boys’ 2015 & Friends**.

About explains the mission: connecting people through safe, voluntary blood donation. The short signature is the only community attribution shown.

The selected emblem is a white handshake inside a crimson blood drop. Its unchanged artwork master is `design-system/brand/handshake-drop.png`; `tools/generate_icons.py` derives platform icons and the admin PNG. Flutter displays the bundled artwork with the same safe padding. Android uses full-colour adaptive foreground/background layers; a monochrome layer is omitted because tinting the raster would erase the white handshake. Manrope is bundled locally without remote font requests.
