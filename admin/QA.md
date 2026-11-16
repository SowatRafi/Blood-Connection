# Admin verification record

Verified on 15 November 2026 with Chrome, the real FastAPI backend, and isolated fictional data under `artifacts/admin-qa-data` on port 8001. The main application's demo data on port 8000 was not modified by these checks.

## Automated checks

`node --test admin/helpers.test.mjs`: five tests pass. They cover required evidence confirmation and review notes, money-request-only permanent bans, already-resolved reports, pending/all filters, secure authentication origins, generic error fallback, invalid dates, and PKCE state/origin/verifier/expiry rejection.

`node --check admin/app.js`: passes.

## Browser checks

- Unconfigured social provider buttons stay disabled, with an explanation rather than a fake login.
- Demo login requires the fictional-data acknowledgment and is visibly marked as a local demo.
- The actual API loads the Bangladesh queue, account references and report-scoped evidence.
- A reviewed fictional money request can be confirmed through the named-account dialog with a note and evidence checkbox. The server result was observed: pending reports 1 → 0, available donors 4 → 3, lifetime bans 0 → 1.
- The all-reports view shows the resolved report with its banned status and removes decision actions.
- Switching to Australia clears Bangladesh evidence, shows the empty regional queue, and preserves the global ban count.
- Sign-out clears report DOM content. A follow-up fix also clears the hidden review note and account reference from the dialog.
- An invalid OAuth callback is rejected and the code/state are removed from the URL.
- A separate non-demo backend on port 8002 exposes no demo button or demo badge. Missing provider configuration remains clearly explained.
- Desktop and 375px viewport screenshots were visually reviewed. No horizontal overflow was measured at the narrow viewport. Visible action/select controls were at least 44px high. Checkboxes use a 48px minimum clickable label.
- Headings, form labels, button names, statuses and the confirmation dialog were inspected through the accessibility tree. The dialog initially focuses its review-note field.
- No app-origin console errors were seen; installed browser extension warnings were unrelated to this app.

## Native administration and identity update

The native Flutter `AdminScreen` uses the same backend moderation endpoints. Four widget tests pass: ordinary members never request or see evidence; server authorization failure clears the inbox even after a role response; the admin page/report fit a 320px phone at 2× text scaling; and permanent bans require a review note plus evidence confirmation. Targeted Flutter analysis reports no issues.

The refreshed identity was reloaded and visually checked in Chrome at `http://127.0.0.1:8000/admin/`, at the normal 1278px desktop viewport and a temporary 375 × 812px viewport. The new heart-in-drop logo rendered correctly in the header and About dialog. The computed font family begins with Manrope, the browser reported fonts loaded, and `document.fonts.check('400 16px Manrope')` returned true.

Sign-in, the fictional demo dashboard/report evidence and About remained readable. The short signature is exactly “An initiative by Bindubashini Boys’ 2015 & Friends”; only one page credit is visible at each breakpoint, About shows it once with the concise donation mission, and the removed full-school text was absent. At 375px the dialog text wrapped and its full-width Close button stayed inside the dialog. Page scroll width equaled content width (360px with the vertical scrollbar on the narrow viewport); no dashboard content element extended beyond that content width. Desktop dashboard scroll width likewise matched its 1263px content width.

No moderation decision or country change was submitted. The existing fictional report remained pending (one report, four available donors, zero bans). The temporary viewport override was reset after verification. The sign-in page continues to explain that administrators can use mobile or website while members use mobile. Screenshots were inspected during this pass; these results do not replace paired-watch, vehicle or iOS hardware verification.

## Remaining verification

The later reporter-image feature has seven passing Node helper/lifecycle tests and eight passing native admin widget tests, with targeted Flutter analysis clean. Native tests additionally cover private-image cache eviction on background/route departure, late-response suppression, evidence authorization failure and generic report reasons that cannot trigger money-only bans. Browser image interaction has not been visually rerun because browser automation is unavailable; the earlier browser checks apply to the previous interface only.

The latest vector/logo source update was inspected separately by the root developer after the browser pass recorded above. Browser automation became unavailable before another live admin reload could be performed, so the earlier typography/layout and signature checks do not claim to verify that final vector revision in Chrome. This does not block the independently tested mobile map changes.

Real Google/Apple/Facebook redirects need the owner's developer accounts and Supabase configuration. Full assistive-technology testing, enforced MFA for production administrators, and formal accessibility certification are not claimed. The native dialog's standard keyboard behavior is used; browser extensions can inject their own controls.
