import { authBase, errorMessage, readableDate, reasonLabels, validateDecision, validOAuthReturn, visibleReports } from './helpers.mjs';
import { PrivateEvidence } from './private-evidence.mjs';

// Access tokens and fetched reports stay in memory. Only the pending PKCE exchange
// uses tab-scoped sessionStorage, because its verifier must survive the provider redirect.
let token = null;
let authConfig = null;
let reports = [];
let selectedId = null;
let selectedDecision = null;
let country = 'BD';
// Every inbox reload, sign-out and background transition invalidates older inbox responses.
let loadVersion = 0;
let submitting = false;
let demo = false;
const $ = id => document.getElementById(id);
const privateImages = new PrivateEvidence();

// Build all server-controlled content as text nodes to prevent stored-message XSS.
function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}

// A single announced status area makes errors visible to sighted and screen-reader users.
function notice(message, isError = false) {
  $('notice').textContent = message;
  $('notice').classList.toggle('error', isError);
  $('notice').setAttribute('role', isError ? 'alert' : 'status');
  $('notice').hidden = !message;
}

// Every API call uses the current country and bearer token; no credentials enter a URL.
async function api(path, options = {}) {
  let response;
  try {
    response = await fetch(`/api/v1${path}`, {
      method: options.method || 'GET',
      headers: { 'Content-Type': 'application/json', 'X-Country': country, ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      cache: 'no-store',
      signal: options.signal ? AbortSignal.any([options.signal, AbortSignal.timeout(15000)]) : AbortSignal.timeout(15000),
    });
  } catch {
    throw new Error('Could not reach the server. Check your connection and try again.');
  }
  if (options.binary && response.ok) return response.blob();
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 401 && token) clearSession();
    // Any forbidden action may mean the administrator role was revoked mid-session.
    if (response.status === 403 || (options.binary && response.status === 404)) {
      clearPrivateImages();
      reports = [];
      selectedId = null;
      $('report-list').replaceChildren();
      $('report-detail').replaceChildren();
      notice(errorMessage(payload, response.status), true);
    }
    throw new Error(errorMessage(payload, response.status));
  }
  return payload;
}

// Clearing the view removes report evidence immediately when an admin signs out.
function clearSession() {
  clearPrivateImages();
  token = null;
  reports = [];
  selectedId = null;
  loadVersion += 1;
  $('report-list').replaceChildren();
  $('report-detail').replaceChildren();
  $('dashboard').hidden = true;
  $('login').hidden = false;
  $('sign-out').hidden = true;
  $('admin-name').textContent = '';
  $('review-dialog').close();
  $('review-form').reset();
  $('dialog-description').textContent = '';
  $('dialog-error').textContent = '';
}

// Authentication alone is insufficient: verify the assigned server role before showing evidence.
async function openConsole(accessToken) {
  token = accessToken;
  try {
    const profile = await api('/me');
    if (profile.role !== 'admin') throw new Error('This account has no administrator access. Ask the project owner to assign the role.');
    const countries = await api('/countries');
    country = countries.items.some(item => item.code === profile.country) ? profile.country : countries.items[0]?.code || 'BD';
    $('country').replaceChildren(...countries.items.map(item => {
      const option = element('option', item.name);
      option.value = item.code;
      return option;
    }));
    $('country').value = country;
    $('admin-name').textContent = profile.display_name || 'Administrator';
    $('login').hidden = true;
    $('dashboard').hidden = false;
    $('sign-out').hidden = false;
    notice('');
    await refreshInbox();
  } catch (error) {
    clearSession();
    notice(error.message, true);
  }
}

// Ignore superseded responses so a slow previous-country request cannot overwrite the inbox.
async function refreshInbox() {
  const version = ++loadVersion;
  clearPrivateImages();
  reports = [];
  $('report-list').replaceChildren();
  $('report-detail').replaceChildren(element('p', 'Loading report evidence…', 'fineprint'));
  $('refresh').disabled = true;
  $('country').disabled = true;
  $('dashboard').setAttribute('aria-busy', 'true');
  try {
    const [summary, data] = await Promise.all([api('/admin/summary'), api('/admin/reports')]);
    if (version !== loadVersion || !token || document.hidden) return;
    reports = data.items;
    $('pending-count').textContent = summary.pending_reports;
    $('donor-count').textContent = summary.active_donors;
    $('ban-count').textContent = summary.banned_accounts;
    if (!reports.some(report => report.id === selectedId)) selectedId = visibleReports(reports, $('status-filter').value)[0]?.id || null;
    renderReports();
    renderDetail();
  } catch (error) {
    if (version === loadVersion) notice(error.message, true);
  } finally {
    if (version === loadVersion) {
      $('refresh').disabled = false;
      $('country').disabled = false;
      $('dashboard').setAttribute('aria-busy', 'false');
    }
  }
}

// The inbox uses real buttons, exposing selection without custom keyboard navigation.
function renderReports() {
  const visible = visibleReports(reports, $('status-filter').value);
  if (!visible.length) {
    const empty = element('div', undefined, 'empty-state');
    empty.append(element('h3', 'A quieter inbox.'), element('p', 'No reports in this view. Refresh to check for new concerns.'));
    $('report-list').replaceChildren(empty);
    return;
  }
  $('report-list').replaceChildren(...visible.map(report => {
    const button = element('button', undefined, 'report-item');
    button.type = 'button';
    button.setAttribute('aria-pressed', String(report.id === selectedId));
    const top = element('div', undefined, 'report-item-top');
    top.append(element('span', reasonLabels[report.reason] || 'Other concern', 'report-reason'), statusBadge(report.status));
    button.append(top, element('p', report.details || 'No description provided.', 'report-preview'), element('span', readableDate(report.created_at), 'report-date'));
    button.addEventListener('click', () => { selectedId = report.id; renderReports(); renderDetail(); });
    return button;
  }));
}

// Status is spelled out as well as colored, so urgency does not depend on color perception.
function statusBadge(status) {
  return element('span', status === 'pending' ? 'Pending' : status === 'banned' || status === 'ban' ? 'Banned' : 'Reviewed', `badge ${status === 'pending' ? 'badge-pending' : 'badge-reviewed'}`);
}

// Show only report-scoped evidence rather than exposing an unrestricted conversation browser.
function renderDetail() {
  clearPrivateImages();
  const report = reports.find(item => item.id === selectedId);
  const detail = $('report-detail');
  detail.replaceChildren();
  if (document.hidden) return;
  if (!report) {
    const empty = element('div', undefined, 'empty-state');
    empty.append(element('h3', 'Your careful review matters.'), element('p', 'Select a report to view the concern and conversation evidence.'));
    detail.append(empty);
    return;
  }
  const heading = element('div', undefined, 'detail-heading');
  heading.append(element('h2', reasonLabels[report.reason] || 'Other concern'), statusBadge(report.status));
  const metadata = element('dl', undefined, 'detail-meta');
  for (const [label, value] of [['Report reference', report.id], ['Received', readableDate(report.created_at)], ['Reported account', report.reported_id], ['Reporter account', report.reporter_id]]) {
    const pair = element('div');
    pair.append(element('dt', label), element('dd', value));
    metadata.append(pair);
  }
  detail.append(heading, metadata, element('h3', 'The concern', 'detail-label'), element('p', report.details || 'No description provided.', 'report-description'), element('h3', 'Conversation evidence', 'detail-label'));
  const evidence = element('div', undefined, 'evidence');
  for (const message of report.evidence || []) {
    const item = element('div', undefined, 'evidence-message');
    const sender = message.sender_id === report.reported_id ? 'Reported account' : message.sender_id === report.reporter_id ? 'Reporter' : 'Participant';
    item.append(element('span', sender, 'message-author'), element('p', message.body, 'message-body'), element('span', readableDate(message.created_at), 'message-date'));
    evidence.append(item);
  }
  if (!evidence.childElementCount) evidence.append(element('p', 'No conversation evidence was attached. A report alone is not proof of misconduct.', 'fineprint'));
  detail.append(evidence);
  const attachments = (report.attachments || []).slice(0, 3);
  if (attachments.length) {
    detail.append(element('h3', 'Submitted images', 'detail-label'), element('p', 'Provided by the reporter. Review these alongside the conversation; an attachment alone is not proof.', 'fineprint'));
    const images = element('div', undefined, 'submitted-images');
    attachments.forEach((attachment, index) => {
      const card = element('div', undefined, 'submitted-image');
      const view = element('button', `View image ${index + 1}`, 'button-secondary');
      view.type = 'button';
      const status = element('p', '', 'fineprint');
      status.setAttribute('role', 'status');
      view.addEventListener('click', async () => {
        view.disabled = true;
        status.textContent = 'Loading private image…';
        try {
          const url = await privateImages.load(signal => api(`/admin/reports/${encodeURIComponent(report.id)}/evidence/${encodeURIComponent(attachment.id)}`, { binary: true, signal }));
          if (!url || !card.isConnected || document.hidden) return;
          const image = element('img');
          image.alt = `Reporter-submitted evidence image ${index + 1}`;
          image.dataset.privateEvidence = '';
          image.src = url;
          card.append(image);
          view.hidden = true;
          status.textContent = 'Private image · cleared when you leave this report or background the page.';
        } catch (error) {
          if (!card.isConnected) return;
          status.textContent = error.message;
          view.disabled = false;
        }
      });
      card.append(view, status);
      images.append(card);
    });
    detail.append(images);
  }
  if (report.status === 'pending') {
    detail.append(element('p', 'A lifetime ban is available only for a confirmed request for money. Review the context and record your reasoning before acting.', 'decision-note'));
    const actions = element('div', undefined, 'decision-actions');
    const dismiss = element('button', 'Dismiss report', 'button-secondary');
    dismiss.addEventListener('click', () => openDecision('dismiss'));
    actions.append(dismiss);
    if (report.reason === 'money_request') {
      const ban = element('button', 'Review lifetime ban', 'button-primary');
      ban.addEventListener('click', () => openDecision('ban'));
      actions.append(ban);
    }
    detail.append(actions);
  } else detail.append(element('p', 'This report has been reviewed. The decision is recorded in the administration audit trail.', 'decision-note'));
}

// Removing src releases image elements before their temporary URLs are revoked.
function clearPrivateImages() {
  document.querySelectorAll('img[data-private-evidence]').forEach(image => image.removeAttribute('src'));
  privateImages.clear();
}

// A separate confirmation step gives permanent decisions a concrete, reviewable consequence.
function openDecision(decision) {
  const report = reports.find(item => item.id === selectedId);
  if (!report || report.status !== 'pending') return;
  selectedDecision = decision;
  $('review-form').reset();
  $('dialog-error').hidden = true;
  $('dialog-title').textContent = decision === 'ban' ? 'Issue a lifetime ban?' : 'Dismiss this report?';
  $('dialog-description').textContent = decision === 'ban' ? `Account ${report.reported_id} will permanently lose access across every country. This decision cannot be reversed in this console.` : 'This closes the report without banning the reported account. Record the reason for your decision.';
  $('ban-confirm-label').hidden = decision !== 'ban';
  $('ban-confirm').required = decision === 'ban';
  $('submit-review').textContent = decision === 'ban' ? 'Confirm lifetime ban' : 'Dismiss report';
  $('review-dialog').showModal();
  $('review-note').focus();
}

// Disable repeated clicks while waiting; the server's locked pending-report check
// is what prevents competing administrators from recording multiple decisions.
async function submitDecision(event) {
  event.preventDefault();
  if (submitting) return;
  const report = reports.find(item => item.id === selectedId);
  const note = $('review-note').value.trim();
  const error = validateDecision(report, selectedDecision, note, $('ban-confirm').checked);
  if (error) { $('dialog-error').textContent = error; $('dialog-error').hidden = false; return; }
  submitting = true;
  $('submit-review').disabled = true;
  $('cancel-review').disabled = true;
  try {
    await api(`/admin/reports/${encodeURIComponent(report.id)}/resolve`, { method: 'POST', body: { decision: selectedDecision, note } });
    $('review-dialog').close();
    notice(selectedDecision === 'ban' ? 'Lifetime ban recorded. This account is blocked worldwide.' : 'Report dismissed. Your review note has been recorded.');
    selectedId = null;
    await refreshInbox();
  } catch (failure) {
    $('dialog-error').textContent = failure.message;
    $('dialog-error').hidden = false;
  } finally {
    submitting = false;
    $('submit-review').disabled = false;
    $('cancel-review').disabled = false;
  }
}

// URL-safe randomness is used for both the PKCE secret and callback binding.
function randomString() {
  return btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

// PKCE prevents a stolen callback code from being exchanged without this browser's secret.
async function startOAuth(provider) {
  try {
    if (!['google', 'apple', 'facebook'].includes(provider) || !authConfig) throw new Error('Social sign-in has not been configured.');
    const verifier = randomString();
    const state = randomString();
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
    const challenge = btoa(String.fromCharCode(...new Uint8Array(digest))).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
    const base = authBase(authConfig.supabase_url);
    // The random flow value binds our return URL; the auth provider handles its own OAuth state.
    sessionStorage.setItem('blood-connection-pkce', JSON.stringify({ verifier, state, base, created: Date.now() }));
    const callback = new URL('/admin/', location.origin);
    callback.searchParams.set('flow', state);
    const authorize = new URL('/auth/v1/authorize', base);
    authorize.search = new URLSearchParams({ provider, redirect_to: callback.href, code_challenge: challenge, code_challenge_method: 's256' });
    location.assign(authorize.href);
  } catch (error) { notice(error.message, true); }
}

// Callback secrets are removed from the address bar before any network or rendering work.
async function finishOAuth(params) {
  if (!params.has('code') && !params.has('error')) return;
  history.replaceState({}, '', '/admin/');
  try {
    const stored = sessionStorage.getItem('blood-connection-pkce');
    sessionStorage.removeItem('blood-connection-pkce');
    const pending = stored ? JSON.parse(stored) : null;
    if (params.has('error')) throw new Error('Sign-in was not completed. Please try again.');
    if (!authConfig || !validOAuthReturn(pending, params.get('flow'), authConfig.supabase_url)) throw new Error('This sign-in request expired or came from another browser. Please sign in again.');
    const response = await fetch(`${pending.base}/auth/v1/token?grant_type=pkce`, { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: authConfig.supabase_anon_key }, body: JSON.stringify({ auth_code: params.get('code'), code_verifier: pending.verifier }), signal: AbortSignal.timeout(15000) });
    const data = await response.json();
    if (!response.ok || !data.access_token) throw new Error('Secure sign-in could not be completed. Please try again.');
    await openConsole(data.access_token);
  } catch (error) { notice(error.message, true); }
}

// A fresh page intentionally requires a fresh session; refresh tokens are not persisted.
async function initialize() {
  const params = new URLSearchParams(location.search);
  // Strip one-time OAuth codes before loading configuration, even if that request fails.
  if (params.has('code') || params.has('error')) history.replaceState({}, '', '/admin/');
  try {
    const [health, config] = await Promise.all([api('/health'), api('/auth/config')]);
    demo = health.demo === true;
    $('demo-badge').hidden = !demo;
    $('demo-login').hidden = !demo;
    if (config.supabase_url && config.supabase_anon_key) {
      authBase(config.supabase_url);
      authConfig = config;
      document.querySelectorAll('[data-provider]').forEach(button => { button.disabled = false; });
      $('auth-status').textContent = 'Use your assigned administrator account to continue.';
    } else $('auth-status').textContent = 'Social sign-in needs Google, Apple or Facebook provider configuration. The project owner has not connected it yet.';
    await finishOAuth(params);
  } catch (error) {
    $('auth-status').textContent = 'The admin server is unavailable. Start the backend and reload this page.';
    notice(error.message, true);
  }
}

// Native event handlers keep controls predictable and avoid inline-script CSP exceptions.
document.querySelectorAll('[data-provider]').forEach(button => button.addEventListener('click', () => startOAuth(button.dataset.provider)));
$('demo-consent').addEventListener('change', () => { $('enter-demo').disabled = !$('demo-consent').checked; });
$('enter-demo').addEventListener('click', async () => {
  if (!demo || !$('demo-consent').checked) return;
  $('enter-demo').disabled = true;
  await openConsole('demo-admin');
  $('enter-demo').disabled = false;
});
$('sign-out').addEventListener('click', async () => {
  const previousToken = token;
  clearSession();
  // Clear local evidence first; a slow provider logout must not leave it visible.
  notice('You have signed out. Report evidence has been cleared from this page.');
  if (authConfig && previousToken && !previousToken.startsWith('demo-')) {
    try { await fetch(`${authBase(authConfig.supabase_url)}/auth/v1/logout?scope=local`, { method: 'POST', headers: { apikey: authConfig.supabase_anon_key, Authorization: `Bearer ${previousToken}` }, signal: AbortSignal.timeout(10000) }); } catch { /* Local sign-out remains effective if the auth server is temporarily unavailable. */ }
  }
});
$('refresh').addEventListener('click', () => { notice(''); refreshInbox(); });
$('country').addEventListener('change', () => {
  country = $('country').value;
  reports = [];
  selectedId = null;
  $('pending-count').textContent = '—';
  $('donor-count').textContent = '—';
  $('ban-count').textContent = '—';
  renderReports();
  renderDetail();
  notice('');
  refreshInbox();
});
$('status-filter').addEventListener('change', () => {
  const visible = visibleReports(reports, $('status-filter').value);
  if (!visible.some(report => report.id === selectedId)) selectedId = visible[0]?.id || null;
  renderReports();
  renderDetail();
});
$('cancel-review').addEventListener('click', () => $('review-dialog').close());
$('review-dialog').addEventListener('cancel', event => { if (submitting) event.preventDefault(); });
$('review-form').addEventListener('submit', submitDecision);
// Hidden tabs must not retain private image previews or restore a superseded response on resume.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    ++loadVersion;
    clearPrivateImages();
    $('report-detail').replaceChildren();
    $('review-dialog').close();
    $('review-form').reset();
  } else if (token) refreshInbox();
});
window.addEventListener('pagehide', clearPrivateImages);
// The concise brand credit opens an accessible explanation of the donation mission.
document.querySelectorAll('[data-about]').forEach(button => button.addEventListener('click', () => $('about-dialog').showModal()));
initialize();
