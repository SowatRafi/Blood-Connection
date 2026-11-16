# Privacy and safety design

This is an engineering data inventory and launch checklist, not a finalized legal privacy notice.

| Data | Purpose | Visibility |
| --- | --- | --- |
| Social identity subject and provider | Sign-in and account continuity | Identity provider and backend |
| Display name, blood group, city | Find appropriate local volunteers | Eligible signed-in searchers |
| Latitude/longitude | Calculate nearby matches | Owner and server; never donor results |
| Coarse geographic area center | Show approximate nearby blood-group areas | Eligible signed-in searchers; shared by all donors in the fixed cell |
| Map tile requests | Render the discovery area or an accepted meeting map | Tile provider sees the device IP and requested map tiles/viewport, without donor IDs or blood groups |
| Height, weight, calculated BMI | Private personal profile | Owner only through ordinary API |
| Availability, donation date/cooldown | Respect consent and recovery pause | Owner; server uses derived eligibility |
| Donation facility, location label, country and optional request reference | Maintain donation history and a matched request outcome | Full history is donor-only; the matched seeker can see the outcome for their request, never unrelated history |
| Shared donation confirmation and per-person dismissal state | Ask both matched participants whether the donation happened; remember who confirmed | Matched donor/seeker and backend; unrelated members excluded |
| Active country | Regional routing during travel | Owner and backend |
| Optional profile photo | Help a matched pair recognize each other | Owner; authenticated accepted counterpart only while the request remains active |
| Shared hospital/meeting point | Coordinate an accepted request and directions | Requester; accepted donor; chosen map/navigation providers when used |
| Push endpoint/token and encryption public keys | Deliver generic background alerts | Owner's installation and backend; notification provider handles delivery metadata |
| Request invitations and notification inbox | Consent, request status and personalized thanks | Intended participants only |
| Report-review events and routing identifiers | Notify the submitter of a review, including after travel | Reporter and backend; providers carry only generic previews and opaque routing metadata |
| Conversation content | In-app coordination | Participants; limited reported evidence to admin |
| Call invitation metadata | Authorize and connect consenting participants | Participants and backend |
| Report submissions and attached images | Investigate reported misconduct | Reporter can read their own submission/attachments; authorized administrators can review; accused members cannot retrieve them |
| Safe report outcome and review timestamp | Let submitters track their reports | Reporter; separate administrative access for review |
| Conversation evidence snapshots, internal review notes and audit records | Investigate abuse and enforce bans | Authorized administrators; excluded from ordinary reporter status/detail responses |
| Minimal ban/deletion identity markers | Prevent re-entry with the same identity | Backend enforcement |

The app never requests contacts or a phone number. A social provider may hold an email address; it is not exposed to donors or seekers. Users should still avoid voluntarily placing numbers or other sensitive data in names or messages. No design can prevent someone manually typing a phone number with arbitrary obfuscation; the privacy promise concerns the app's own collection and disclosure.

## Consent and permissions

Location is requested in the foreground for nearby matching. Automatic-mode consent explains that country and area follow the member during travel. A manual override stays in effect until automatic mode is selected again. Native platform geocoding can process coordinates or place queries through Google/Apple services; street addresses are not used as public area labels. Microphone access is requested for in-app audio. There is no background location permission. Donors can turn availability off. Returning from cooldown does not override that choice. Use a display name that the member is comfortable sharing.

## Approximate donor map

The nearby map uses **approximate areas, not donor pins**. The server maps private coordinates to fixed global cells: roughly 5.56 km north–south and at least approximately 5 km east–west, with each small polar cap treated as a single area. All donors in a cell share one ID and centroid; repeated requests do not produce different random offsets that could be averaged to reconstruct a location. Antimeridian cells wrap consistently. The client groups these returned areas and never receives a donor's precise coordinates. Area centers can cross country borders, fall over water or sit outside a small search radius; they are not destinations for navigation.

This reduces direct map disclosure but is not an anonymity guarantee. Exact-radius eligibility filtering remains in place, so repeated searches from permitted origins, multiple accounts, changing radii or observing movement can reveal more than the coarse map alone. Origin checks and rate limits reduce abuse but do not eliminate this inference risk. Public deployment still needs abuse monitoring and a reviewed location-privacy policy; do not describe this as exact location secrecy against a determined searcher.

## Photos, notifications and minimal registration

Photos are optional after registration. The server accepts bounded JPEG/PNG input and re-encodes a small image without EXIF metadata. Photos have no public URL; every read checks the current accepted relationship, account state and blocking rules. Closing a request revokes further access. Previously viewed content cannot be recalled from another person's memory or screenshots. The mobile app does not save profile photos to shared storage and clears its image cache when their screen closes.

Push previews contain generic text and opaque identifiers, never names, blood groups, measurements, photos or meeting coordinates. Personalized thanks remain in the authenticated inbox. Android UnifiedPush payloads are encrypted to the installation's key. Apple notification delivery uses APNs. Both systems can delay or suppress alerts according to connectivity, permissions and device settings. No emergency-delivery guarantee is made.

Report-review pushes contain report/event IDs and stored routing countries, without the allegation, review outcome, attachments or internal review note. A stored report country can differ from the recipient's current location; travel does not make the report public. Report outcomes intentionally remain deliverable while the reporter is offline as a donor, in cooldown, or has blocked the accused. Those donor preferences suppress applicable donation alerts, not updates about the member's own safety reports. Banned/deleted recipients remain excluded. Real APNs device delivery has not been verified in this Windows workspace; the implemented adapter and its tests are not a delivery guarantee.

Registration asks for a display name, blood group, height and weight, plus automatic or manually selected country/area and voluntary donor availability. BMI is derived, not another form field. A phone number, separately entered email, birth date, home address, identity document and payment details are not requested. Photo and notification setup are optional; a meeting destination is requested only when creating a blood request.

Height and weight unit choices are local, per-account display preferences. The app converts supported metric/imperial input to canonical centimetres (`height_cm`) and kilograms (`weight_kg`) for API storage and BMI calculation. Choosing another display unit does not add a new medical field or change who can see the measurements; they remain private profile data.

## Private donation history

A completed coordination request does not itself prove that blood was donated. It creates a receipt accessible to the accepted donor and seeker, retaining their IDs, the donor's display name, the shared meeting name, country and completion time. The meeting name is only an editable suggestion. The receipt does not restore the other person's photo or exact destination access after closure.

Either matched participant may confirm the date, hospital/blood-bank, location label and country. The first saved Yes creates one record against the actual donor and starts or extends that donor's pause. The record retains who confirmed it. A seeker's Yes never becomes a donation by the seeker. Each person's No dismisses only their own reminder, and Later leaves it pending. Confirmation by a participant is not clinical verification. Locations are explicit input, never inferred from GPS.

Full donation history remains donor-only. The accepted pair can see the outcome for their own request, including the confirmer's role. Unrelated donors, searchers and ordinary admin moderation endpoints cannot browse a donor's full history. Shared receipt state and history remain in the registry across travel; production residency decisions must account for this health-related data. Export/deletion apply to owned records, while shared factual outcomes and moderation evidence require the documented retention policy. Database operators still need access controls; storage is not end-to-end encrypted.

## Reports and bans

Both matched participants can report from their request or conversation, including after closure or blocking. A report records a reason, an explanation and a limited conversation snapshot. They can attach up to three JPEG/PNG screenshots or photos, each at most 5 MiB. The server validates image content/dimensions and re-encodes without EXIF metadata; it does not accept SVG, arbitrary documents or external evidence URLs. Metadata stripping does not remove private information visible inside a screenshot: users should select only relevant evidence.

Attachments are stored with the report in its regional database. Authenticated reporter access and authenticated admin evidence routes return no-store bytes, not reusable public links. The accused person cannot use reporter endpoints to retrieve attachments; the admin viewer clears its displayed image data when leaving or hiding the view. Current administrators have global moderation roles with a selected region, not per-country assignment lists. Evidence remains moderation data under retention rules rather than being erased when a requester closes the request.

The member's **My reports** view lists only their own submissions, across countries, with pending/reviewed status, a safe fixed outcome explanation and the review time where known. Both donors and seekers have this access. It includes their submitted reason, details and attachment metadata, but never an internal administrator note, audit record or the stored conversation-evidence snapshot. Detail and attachment reads can select the original stored country after travel while retaining reporter authorization; a guessed ID or knowledge of the country grants no access. A legacy review may have an unknown timestamp rather than an invented date.

An administrator's ban or dismissal creates one reporter inbox event and its delivery entries atomically with the review. The accused is not notified through the reporter's outcome channel. Repeated review submissions cannot create another event, although transport retries can deliver more than once and the client deduplicates regional event IDs. Only authenticated report detail reveals the outcome. Blocking, closing a donation request, or changing donor availability does not remove the reporter's access to their own submitted report.

Reporting creates a pending review and preserves limited evidence. A report is not proof. The administrator must review a money request and enter a reason before imposing the requested lifetime account ban. Keep an appeal/contact process outside the app before launch, and provide moderation staffing. This build enforces against linked account identity, not a verified unique human across every provider account.

## Retention and deletion

Local test data lives under the ignored backend data directory. It is not encrypted by SQLite itself. Protect the workstation account and disk. Production requires encrypted disks, encrypted backups, a secret manager, least-privilege filesystem/database access, and tested restoration.

The export and deletion endpoints operate on the authenticated member's records. Deletion minimizes profile and message content; minimal ban/deletion and audit evidence can remain to uphold safety. Final retention periods, legal basis, appeal periods, backup deletion timelines, report evidence expiry, and handling of shared conversation records must be selected before collecting real users' health-related data. Do not promise immediate erasure from every backup or identity provider unless that lifecycle has been implemented and verified.

## Encryption claims

Production API traffic requires HTTPS. LiveKit uses its configured secure media transport. Ordinary messages are stored server-side for participant access and reporting. This build does not implement end-to-end encrypted chat or claim that administrators cannot access stored content. End-to-end media encryption requires additional key management; do not advertise it based only on transport encryption.

## Launch decisions still owned by the community

Choose the operating organization, privacy contact, moderation appeals contact, minimum user age, regional hosting policy, verified blood-service partnerships, and data-retention schedule. Ensure the final notices describe implemented behavior and supported countries. Review emergency guidance and country-specific donor rules with qualified local services.
