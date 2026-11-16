# Blood Connection admin console

An initiative by Bindubashini Boys’ 2015 & Friends

The admin app uses plain HTML, CSS and JavaScript. There is no build step and no third-party browser script. The backend serves this directory at `http://127.0.0.1:8000/admin/`.

## Local use

1. Run the backend in explicitly enabled local demo mode as documented in the project README.
2. Open `/admin/`, acknowledge fictional demo accounts, then select **Open demo console**.
3. Choose the country and a report. Review its description and conversation evidence. Select **View image** to privately load any reporter-submitted attachment.
4. Dismiss with a reason, or confirm a money request and issue a lifetime ban. Bans apply worldwide. Decisions require backend authorization and a permanent audit record.

The console does not auto-ban on a report. It exposes no unrestricted user or conversation browser. Do not use real personal information in the local demo. A demo ban changes the demo database, so use a disposable test database when testing that workflow.

## Real sign-in setup

The backend's public `/api/v1/auth/config` endpoint must return `supabase_url` and `supabase_anon_key`. The anonymous/publishable key is public configuration; never return a service-role key. Enable Google, Apple and Facebook in Supabase, configure their developer accounts, and allow the admin return URL including its query parameters (`https://your-host/admin/**` in the redirect allowlist). Grant administrator roles through the backend's owner-managed configuration; the browser cannot assign a role.

Social sign-in uses the [Supabase PKCE flow](https://supabase.com/docs/guides/auth/sessions/pkce-flow) and its [documented auth endpoints](https://github.com/supabase/auth/blob/master/openapi.yaml). The verifier and a callback binding are stored in `sessionStorage` and remain valid for at most ten minutes. They are consumed on return. Access tokens live only in JavaScript memory; refresh tokens are discarded. Reloading the page requires signing in again. The API validates every protected request. Sign-out clears report evidence and attempts to revoke the current Supabase session.

Host the app and API on the same HTTPS origin. No cross-origin API exception or embedded third-party script is needed. Configure a restrictive Content Security Policy allowing scripts/styles from self and connections to self plus the configured Supabase URL. The backend must disable caching for authenticated data, enforce authorization and rate limits, and reject demo credentials in production.

## Behavior and limits

- Country switching clears the old report evidence before loading the next country's data.
- Reporter-supplied text and messages are rendered with `textContent`, never HTML.
- Images use authenticated requests and temporary Blob URLs, with no token in the URL. Leaving a report, changing country, signing out or backgrounding the page aborts pending previews and revokes loaded URLs. Returning to the page reloads the authorized inbox.
- The permanent-ban dialog names the affected account and requires a review note plus an explicit evidence confirmation.
- Google/Apple/Facebook buttons are disabled until real provider configuration exists. Demo access appears only when the server explicitly reports `demo: true`.
- No token persistence, analytics, donor phone numbers or precise donor locations are added by this console.
- There is no bulk-ban action or ban reversal control.
- Google, Apple and Facebook redirects require real developer accounts and were not end-to-end verified in the credential-free local build.

## Checks

Run `node --test admin/helpers.test.mjs admin/private-evidence.test.mjs` from the repository root. The seven tests cover permanent-decision constraints, report filtering, safe auth URL handling, non-sensitive errors, preview cancellation/revocation and invalid image rejection. UI verification should also exercise keyboard traversal, the native dialog, narrow screens, browser zoom and the running API. Server-side authorization tests are maintained under `backend/`.
