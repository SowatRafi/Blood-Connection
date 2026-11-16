# Donation status and private history

An initiative by Bindubashini Boys’ 2015 & Friends

## Availability and the recovery pause

Home shows a compact **Available to donate**, **Offline** or **In cooldown** row. Available/offline states have a direct switch, and cooldown keeps its remaining time visible. Tap the row or its expand button for Donation settings, the full explanation, the recovery end date/time, Record donation and Donation history. Profile retains the detailed status. The willingness setting during recovery applies after the pause; switching on cannot bypass the server deadline. Someone who chooses offline stays offline after expiry.

The app's pause is three calendar months after the reported donation date, with month-end clamping, rather than a fixed 90 days. The server validates the date using the supplied bounded UTC offset and persists the corresponding UTC deadline. It keeps the later deadline when an older donation is added. New dates cannot be in the future. Legacy date-only deadlines retain their UTC-midnight interpretation. The UI's countdown updates while visible and on resume, but a device clock or display does not grant server eligibility.

This status describes the app's availability rule. It is not a clinical assessment, a verified donation certificate or a promise that a blood service will accept the donor. The hospital/blood bank determines actual eligibility.

## Record an actual donation

**Record donation** asks for the donation date, hospital or blood-bank name, location/area and country. The country is where that donation occurred and may differ from the current search country. Place labels are explicit personal input; current GPS is not substituted. The saved entry is private to its owner and appears in **Donation history**, including after travel.

The history lists date, facility and place/country. Older rows without place details remain valid history and display missing details as not recorded. The migration does not invent a facility or location. Adding history starts or extends the recovery pause only if its calculated deadline is later than the existing one.

## Confirmation after a completed request

Completing a request means coordination ended. Either matched participant can complete it. Both the accepted donor and the seeker then receive a confirmation reminder; completion alone records no donation and starts no cooldown.

- **Yes, record:** either person reviews the date, facility, area and country, then saves. This records one donation against the actual donor and applies the donor's recovery pause. It does not make a seeker into a donor or expose the donor's full private profile.
- **No donation:** dismisses only that person's reminder. It does not veto the other person's Yes, create a donation or change cooldown.
- **Later:** leaves that person's reminder pending, reachable from the donation history/confirmation screen.

The first successful Yes wins. Concurrent or repeated confirmations cannot create a second donation for the same request. The record keeps who confirmed it; a participant report is not a clinical certificate. The donor can see their own history and the matched pair can see the recorded result for their request. A seeker cannot browse the donor's unrelated donation history.

The reminder keeps the agreed meeting name and country as editable suggestions, plus the matched identities needed to apply the record to the donor. The actual locality must be entered, rather than inferred from GPS. Photos and destination-coordinate access remain revoked after request closure. Pending confirmation state survives travel. Legacy requests are not silently turned into fresh requests to confirm.

Both participants can report a concern from their matched request or conversation and submit evidence. A disputed confirmation should be reported for review; it does not automatically erase a record, shorten cooldown or ban someone.

## Retry and correction boundaries

A request-linked save is idempotent: one completed request can produce one donation record, including concurrent submissions. Repeating the same linked save returns the submitting person's current profile and does not overwrite the recorded details. A dismissed receipt may still be explicitly confirmed later through a linked save; a recorded receipt cannot be dismissed.

The mobile recorder keeps one random idempotency key for the current entry. If the server saves successfully but the response is lost, retrying those same details uses that key and returns the existing result without another history row. Changing the details after that save returns a conflict rather than overwriting it; review Donation history before starting a new entry. Reopening the recorder starts a distinct entry. API clients that omit the optional key do not gain manual retry deduplication.

Logging manually and later confirming the same real-world donation through a request also requires care: those paths are not automatically reconciled. Prefer **Review donation** on an existing pending reminder for that request. The server does not merge records based on similar dates or place names. There is no individual history edit/delete endpoint in this build; full account export and deletion include the history and receipt states. These limits must not be described as a complete medical-record correction workflow.

## Storage and verification

The shared registry stores donation history and confirmation states so travel cannot lose history or reset the pause. Country-specific request records still retain their regional boundary; a private completion receipt is an intentional global matched-participant record. Ordinary donor search and admin moderation endpoints expose no facility/location history. Production storage, residency and retention decisions must account for this additional health-related data.

See [API contract](API.md), [privacy inventory](PRIVACY.md) and [verification guide](TESTING.md). Test cases and walkthroughs describe expected behavior; [delivery notes](DELIVERY.md) separately record what was actually verified.
