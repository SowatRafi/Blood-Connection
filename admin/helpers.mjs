// Known report reasons receive consistent labels; app.js renders every label with textContent.
export const reasonLabels = { money_request: 'Request for money', harassment: 'Harassment', misleading_information: 'Misleading information', no_show: 'Missed meeting', other: 'Other concern' };

// Invalid server dates should read as unavailable instead of crashing the inbox.
export function readableDate(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? 'Date unavailable' : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date);
}

// Frontend checks explain mistakes early; the backend must independently authorize decisions.
export function validateDecision(report, decision, note, confirmed) {
  if (!report || report.status !== 'pending') return 'This report is no longer awaiting review. Refresh the inbox.';
  if (!['ban', 'dismiss'].includes(decision)) return 'Choose a valid review decision.';
  if (note.trim().length < 5 || note.trim().length > 2000) return 'Write a review note between 5 and 2,000 characters.';
  if (decision === 'ban' && report.reason !== 'money_request') return 'Lifetime bans require a confirmed request for money.';
  if (decision === 'ban' && !confirmed) return 'Confirm that you reviewed evidence of a request for money.';
  return null;
}

// Normalize validation responses without displaying object dumps or sensitive payloads.
export function errorMessage(payload, status) {
  if (typeof payload?.detail === 'string') return payload.detail;
  if (status === 401) return 'Your session has expired. Please sign in again.';
  if (status === 403) return 'This account is not permitted to perform this action.';
  if (status === 429) return 'Too many requests. Please wait a moment and try again.';
  return 'The request could not be completed. Please try again.';
}

// Filter only the already-authorized inbox; country scoping belongs to the API request.
export function visibleReports(reports, filter) {
  return reports.filter(report => filter === 'all' || report.status === 'pending');
}

// Public auth configuration must still point to a secure, unambiguous endpoint.
export function authBase(raw) {
  const url = new URL(raw);
  if (url.username || url.password || url.search || url.hash || (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)))) throw new Error('Sign-in requires a secure authentication server.');
  return url.origin;
}

// Bind a callback to this tab, its original auth server and a short validity window.
export function validOAuthReturn(pending, flow, configuredUrl, now = Date.now()) {
  if (!pending || typeof pending !== 'object') return false;
  const safeRandom = /^[A-Za-z0-9_-]{43}$/;
  if (!safeRandom.test(pending.verifier) || !safeRandom.test(pending.state) || pending.state !== flow) return false;
  const age = now - pending.created;
  return Number.isFinite(pending.created) && age >= 0 && age <= 600000 && pending.base === authBase(configuredUrl);
}
