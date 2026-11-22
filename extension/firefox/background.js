// Background (Chrome/Edge service worker, Firefox event page): holds the
// unlocked vault, talks to Drive, answers messages from the popup and from
// the content script running in every page.
//
// This file is shared verbatim by the Chrome and Firefox builds
// (tools/sync-shared.js); browser differences live in lib/drive.js,
// lib/config.js and the manifests.
//
// Security model:
//  * Messages from content scripts are UNTRUSTED. A page's renderer can be
//    compromised, and then it can send anything the content script could.
//    So the page's identity comes from `sender.url` (set by the browser,
//    not by the message) and page-originated requests are limited to that
//    site's own entries; vault-wide operations are popup-only.
//  * The unlocked state is mirrored into storage.session so the service
//    worker can be restarted without asking for the master password again.
//    storage.session is memory-only and — kept at its default access level
//    — readable only by extension pages, never by content scripts. The
//    master password itself is never stored there, only the derived key.
import './lib/psl-data.js';
import './lib/domain.js';
import {
  parseBlob,
  deriveKeyRaw,
  decryptWithKeyRaw,
  encryptWithKeyRaw,
  newId,
  randomBytes,
  randomInt,
  WrongPasswordError,
  CorruptVaultError,
} from './lib/crypto.js';
import * as drive from './lib/drive.js';
import { kvGet, kvSet, kvDelete } from './lib/kv.js';

const api = globalThis.browser ?? globalThis.chrome;
// UI language: Turkish when the browser is set to Turkish, English otherwise.
const isTr = /^tr\b/i.test(api.i18n?.getUILanguage?.() || navigator.language || '');
const t = (tr, en) => (isTr ? tr : en);
const Domain = globalThis.KasaDomain;
const EXT_ORIGIN = api.runtime.getURL('');

// Keep storage.session for trusted (extension) contexts only. An earlier
// version opened it to content scripts; that setting must not linger.
try {
  api.storage.session.setAccessLevel?.({ accessLevel: 'TRUSTED_CONTEXTS' })?.catch?.(() => {});
} catch {
  /* not supported in this browser — default is trusted-only anyway */
}
// Leftovers from versions where content scripts wrote these themselves.
api.storage.session.remove(['kasaPendingSave', 'kasaLastIdentifier']).catch(() => {});
api.storage.local.remove(['kasaPendingSave', 'kasaLastIdentifier']).catch(() => {});

// The real lock boundary is the browser closing: storage.session is wiped
// on exit. This idle timer is a backstop for an unattended machine.
const IDLE_LIMIT_MS = 60 * 60 * 1000; // 1 hour

/** @type {{salt:Uint8Array, keyRaw:Uint8Array, entries:any[]}|null} */
let state = null;
let lastActivity = 0;
// Only in memory, only while this worker lives: needed solely to re-derive
// the key when the Drive copy turns out to use a different salt.
let masterPassword = null;
// Bumped by lock(): a restore that was already reading storage.session
// must not unlock the vault again right after.
let lockGeneration = 0;

// Only the user's own actions count (the popup, picking or saving a login
// on a page), never a page's lookups. Also kept in storage.session, so a
// worker restart doesn't move the idle deadline.
function touch() {
  lastActivity = Date.now();
  api.storage.session.set({ vaultActivity: lastActivity }).catch(() => {});
}

async function persistSession() {
  if (!state) {
    await api.storage.session.remove('vault');
    return;
  }
  await api.storage.session.set({
    vault: {
      salt: [...state.salt],
      keyRaw: [...state.keyRaw],
      entries: state.entries,
      lastActivity,
    },
  });
}

// Messages arriving together at worker start share one restore, and a
// restore never replaces a state that was set (or locked) meanwhile.
let restoring = null;
function restoreSession() {
  if (state) return Promise.resolve();
  restoring ??= restoreNow().finally(() => {
    restoring = null;
  });
  return restoring;
}

async function restoreNow() {
  const generation = lockGeneration;
  const { vault, vaultActivity } = await api.storage.session.get(['vault', 'vaultActivity']);
  if (state || !vault || generation !== lockGeneration) return;
  const last = Math.max(vault.lastActivity || 0, vaultActivity || 0);
  if (Date.now() - last > IDLE_LIMIT_MS || vault.password !== undefined) {
    // Expired — or written by an older version that also kept the master
    // password here. Drop it; the user just unlocks again.
    await api.storage.session.remove('vault');
    return;
  }
  state = {
    salt: new Uint8Array(vault.salt),
    keyRaw: new Uint8Array(vault.keyRaw),
    entries: vault.entries,
  };
  lastActivity = last;
}

async function lock() {
  lockGeneration += 1;
  state = null;
  masterPassword = null;
  await persistSession();
  // Typed passwords and identifiers waiting for a save prompt go too.
  await api.storage.session.remove(['pending', 'identifiers']);
}

function encryptState() {
  return encryptWithKeyRaw(state.entries, state.keyRaw, state.salt);
}

// Every local change goes through a full sync (download, merge, upload):
// uploading local state directly used to overwrite whatever the app on
// another device had added or deleted since this extension last synced.
// Returns null, or why the change is only on this device for now.
async function saveAndUpload() {
  await persistSession(); // the change survives a worker restart
  try {
    await sync();
    return null;
  } catch (e) {
    await keepUnsynced();
    return t('Bu cihaza kaydedildi, Drive’a henüz yüklenemedi', 'Saved on this device, not uploaded to Drive yet') +
      `: ${syncErrorText(e)}`;
  }
}

// A change that couldn't reach Drive (offline, a Drive error, the password
// changed elsewhere) is kept encrypted like the Drive copy: it survives
// locking and closing the browser, is retried every few minutes, and is
// merged in again on the next unlock. It lives in the extension's own
// IndexedDB (lib/kv.js), which content scripts can't read; earlier versions
// kept it in storage.local, which they can, and that copy is moved over.
async function keepUnsynced() {
  await kvSet('unsynced', new TextDecoder().decode(await encryptState()));
  await api.storage.local.remove('unsynced');
  api.alarms.create('sync-retry', { delayInMinutes: 2 });
}

async function getUnsynced() {
  const kept = await kvGet('unsynced');
  if (kept) return kept;
  const { unsynced: legacy } = await api.storage.local.get('unsynced');
  if (!legacy) return null;
  await kvSet('unsynced', legacy);
  await api.storage.local.remove('unsynced');
  return legacy;
}

async function dropUnsynced() {
  await kvDelete('unsynced');
  await api.storage.local.remove('unsynced');
}

// Merges the kept copy into the state just unlocked; [keys] are vaults
// whose key may already fit it, before deriving one from [password].
async function takeInUnsynced(password, keys) {
  const unsynced = await getUnsynced();
  if (!unsynced) return false;
  try {
    const blob = parseBlob(new TextEncoder().encode(unsynced));
    const known = keys.find((k) => k && sameBytes(k.salt, blob.salt));
    const keyRaw = known ? known.keyRaw : await deriveKeyRaw(password, blob.salt);
    return mergeIn(await decryptWithKeyRaw(blob, keyRaw));
  } catch {
    return false; // under a password this device no longer has
  }
}

function syncErrorText(e) {
  const m = String(e?.message || e);
  if (m === 'NEEDS_UNLOCK') {
    return t(
      'Drive’daki kasa başka bir şifreyle yeniden şifrelenmiş; senkron için kilidi yeniden açın',
      'The vault on Drive was re-encrypted; unlock again to sync',
    );
  }
  if (m === 'SYNC_PASSWORD_MISMATCH') {
    return t("Drive'daki kasa farklı bir ana şifre kullanıyor", 'The vault on Drive uses a different master password');
  }
  return m;
}

function mergeIn(incoming) {
  let changed = false;
  for (const r of incoming) {
    const i = state.entries.findIndex((x) => x.id === r.id);
    if (i < 0) {
      state.entries.push(r);
      changed = true;
    } else if (r.updatedAt > state.entries[i].updatedAt) {
      state.entries[i] = r;
      changed = true;
    }
  }
  return changed;
}

function localIsAhead(remote) {
  const byId = new Map(remote.map((r) => [r.id, r]));
  return state.entries.some((l) => {
    const r = byId.get(l.id);
    return !r || l.updatedAt > r.updatedAt;
  });
}

const sameBytes = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

async function sync() {
  const remoteBytes = await drive.download();
  if (!remoteBytes) {
    await drive.upload(await encryptState());
    return t('Drive’a yüklendi', 'Uploaded to Drive');
  }
  const blob = parseBlob(remoteBytes);
  const sameSalt = sameBytes(blob.salt, state.salt);
  let remoteKey;
  if (sameSalt) remoteKey = state.keyRaw;
  else if (masterPassword) remoteKey = await deriveKeyRaw(masterPassword, blob.salt);
  else throw new Error('NEEDS_UNLOCK');
  let remote;
  try {
    remote = await decryptWithKeyRaw(blob, remoteKey);
  } catch (e) {
    if (e instanceof WrongPasswordError) throw new Error('SYNC_PASSWORD_MISMATCH');
    throw e;
  }
  const changed = mergeIn(remote);
  if (!sameSalt || localIsAhead(remote)) await drive.upload(await encryptState());
  await persistSession();
  // Drive has everything now, including what was kept for later.
  await dropUnsynced();
  api.alarms.clear('sync-retry');
  return changed ? t('Drive’dan güncellendi', 'Updated from Drive') : t('Senkronize', 'In sync');
}

// Same minimum as the Passlune app.
const MIN_MASTER_LENGTH = 10;

async function actionCreate(password) {
  const salt = randomBytes(16);
  state = { salt, keyRaw: await deriveKeyRaw(password, salt), entries: [] };
  masterPassword = password;
  touch();
  return saveAndUpload();
}

// Creating a vault is its own, explicit step (the popup asks for the new
// master password twice). Unlock used to create one silently when Drive had
// none, so a mistyped first password became an unrecoverable master password.
async function actionUnlock(password) {
  const remoteBytes = await drive.download();
  if (!remoteBytes) throw new Error('no_vault');
  const blob = parseBlob(remoteBytes);
  const keyRaw = await deriveKeyRaw(password, blob.salt);
  const entries = await decryptWithKeyRaw(blob, keyRaw); // throws WrongPasswordError
  const previous = state;
  state = { salt: blob.salt, keyRaw, entries };
  masterPassword = password;
  touch();
  await persistSession();
  // Changes that never made it to Drive before the last lock or restart.
  if (await takeInUnsynced(password, [state, previous])) return saveAndUpload();
  return null;
}

function liveEntries() {
  return state.entries.filter((e) => !e.deleted);
}

function summary(list) {
  return list
    .map((e) => ({ id: e.id, site: e.site, username: e.username }))
    .sort((a, b) => a.site.localeCompare(b.site));
}

// ------------------------------------------- per-tab state for content.js

// A login usually navigates (often through a redirect or two) right after
// the click, destroying the page's "save password?" banner before it can be
// clicked. The content script hands the candidate to us; the next page in
// the same tab asks for it back. Multi-step logins (e-mail first, password
// on the next screen) likewise hand us the identifier typed on step one.
// Kept per tab and per site (an embedded frame of another site can't
// replace the page's own), short-lived, dropped on lock, and in
// trusted-only storage.session so a worker restart doesn't lose it.
const PENDING_TTL_MS = 20000;
const PENDING_MAX_SHOWS = 2;
const IDENTIFIER_TTL_MS = 10 * 60 * 1000;
const TAB_STORE_TTL = { pending: PENDING_TTL_MS, identifiers: IDENTIFIER_TTL_MS };

// { [tabId]: [{ site, ts, ... }] }, with whatever has expired dropped for
// every tab, so nothing typed lingers longer than it is useful.
async function tabStore(kind) {
  const all = (await api.storage.session.get(kind))[kind] || {};
  for (const [tab, list] of Object.entries(all)) {
    const fresh = (Array.isArray(list) ? list : []).filter((r) => Date.now() - r.ts < TAB_STORE_TTL[kind]);
    if (fresh.length) all[tab] = fresh;
    else delete all[tab];
  }
  return all;
}

function putRecord(all, tabId, record) {
  const others = (all[tabId] || []).filter((r) => !Domain.matches(r.site, record.site));
  all[tabId] = [...others, record].slice(-4);
}

function findRecord(all, tabId, pageUrl) {
  return (all[tabId] || []).filter((r) => Domain.matches(r.site, pageUrl)).pop();
}

function dropRecords(all, tabId, pageUrl) {
  if (all[tabId]) all[tabId] = all[tabId].filter((r) => !Domain.matches(r.site, pageUrl));
}
async function saveTabStore(kind, value) {
  await api.storage.session.set({ [kind]: value });
}

api.tabs.onRemoved.addListener(async (tabId) => {
  for (const kind of ['pending', 'identifiers']) {
    const all = await tabStore(kind);
    if (all[tabId]) {
      delete all[tabId];
      await saveTabStore(kind, all);
    }
  }
});

// ---------------------------------------------------------- clipboard clear

// Copying from the popup used to schedule the clear in the popup itself,
// which dies as soon as the popup closes — i.e. the moment the user clicks
// into a page to paste. The background clears it instead. Chrome's service
// worker has no DOM, so it uses an offscreen document; Firefox's background
// page can do it directly. (Unconditional: we can't read the clipboard to
// check it's still ours without asking for clipboard-read permission.)
const CLIPBOARD_CLEAR_MS = 20000;
let clipboardTimer = null;

function copyEmptyString(doc) {
  const onCopy = (e) => {
    e.clipboardData.setData('text/plain', '');
    e.preventDefault();
  };
  doc.addEventListener('copy', onCopy, true);
  try {
    doc.execCommand('copy');
  } finally {
    doc.removeEventListener('copy', onCopy, true);
  }
}

async function clearClipboardNow() {
  clearTimeout(clipboardTimer);
  clipboardTimer = null;
  await api.storage.session.remove('clipboardClearAt');
  if (typeof document !== 'undefined') {
    copyEmptyString(document); // Firefox background page
    return;
  }
  if (!api.offscreen) return;
  try {
    const has = (await api.offscreen.hasDocument?.()) ?? false;
    if (!has) {
      await api.offscreen.createDocument({
        url: 'offscreen.html',
        reasons: ['CLIPBOARD'],
        justification: 'Clear a copied password from the clipboard after 20 seconds.',
      });
    }
    await api.runtime.sendMessage({ target: 'offscreen', type: 'CLEAR_CLIPBOARD' }).catch(() => {});
    await api.offscreen.closeDocument().catch(() => {});
  } catch (e) {
    console.warn('Passlune: pano temizlenemedi', e);
  }
}

async function scheduleClipboardClear() {
  clearTimeout(clipboardTimer);
  const at = Date.now() + CLIPBOARD_CLEAR_MS;
  await api.storage.session.set({ clipboardClearAt: at });
  clipboardTimer = setTimeout(clearClipboardNow, CLIPBOARD_CLEAR_MS);
  // Backstop if the service worker is stopped before the timer fires
  // (Chrome rounds alarms up to 30 s).
  api.alarms.create('clipboard-clear', { when: at });
}

// ------------------------------------------------------------- generator

function generatePassword(length) {
  const n = Math.min(Math.max(Number(length) || 18, 8), 128);
  const pools = [
    'abcdefghijkmnopqrstuvwxyz',
    'ABCDEFGHJKLMNPQRSTUVWXYZ',
    '23456789',
    '!@#$%^&*()-_=+[]{};:,.?',
  ];
  const all = pools.join('');
  const chars = pools.map((p) => p[randomInt(p.length)]);
  while (chars.length < n) chars.push(all[randomInt(all.length)]);
  for (let i = chars.length - 1; i > 0; i--) {
    const j = randomInt(i + 1);
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }
  return chars.join('');
}

// ------------------------------------------------------------- messaging

class Forbidden extends Error {}

function cleanString(v, max = 2048) {
  return typeof v === 'string' ? v.slice(0, max) : '';
}

// "Update the password?" on a page replaces the stored one with what was
// typed there; a mistyped password accepted that way would lose the real
// one, so the old password stays in the notes (only the latest one).
const PREVIOUS_LINE = /^(Önceki şifre|Previous password) \(\d{4}-\d{2}-\d{2}\): /;
function withPreviousPassword(notes, old) {
  const lines = (notes || '').split('\n').filter((l) => !PREVIOUS_LINE.test(l));
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  lines.push(`${t('Önceki şifre', 'Previous password')} (${new Date().toISOString().slice(0, 10)}): ${old}`);
  return lines.join('\n').slice(-8192);
}

// Requests a web page's content script may make, always about the page's
// own site as reported by the browser (sender.url).
async function handlePageMessage(msg, sender) {
  const pageUrl = sender.url || '';
  const tabId = sender.tab?.id;
  if (!/^https?:/i.test(pageUrl) || tabId === undefined) throw new Forbidden();
  const host = Domain.hostOf(pageUrl);
  // Plain http on a public host: anyone on the network can read and change
  // the page. It is never handed a stored login (the popup can still fill
  // one, after a warning) nor what was typed on the site's https pages.
  const insecure = /^http:/i.test(pageUrl) && !Domain.isPrivateHost(pageUrl);
  const reachable = (record) => record && !(insecure && !/^http:/i.test(record.site));

  switch (msg.type) {
    case 'LIST': {
      if (!state) return { ok: false, error: 'locked' };
      if (insecure) return { ok: true, entries: [] };
      return { ok: true, entries: summary(liveEntries().filter((e) => Domain.matches(e.site, pageUrl))) };
    }
    case 'REVEAL': {
      if (!state) return { ok: false, error: 'locked' };
      if (insecure) return { ok: false, error: 'insecure' };
      const e = liveEntries().find((x) => x.id === msg.id);
      // Only this site's own logins can be revealed to it.
      if (!e || !Domain.matches(e.site, pageUrl)) return { ok: false, error: 'not_found' };
      touch(); // the user picked it
      return { ok: true, username: e.username, password: e.password };
    }
    case 'SAVE_CHECK': {
      // Whether "Save the password?" has anything new to offer — answered
      // here, so the stored passwords never go to the page to compare.
      if (!state) return { ok: false, error: 'locked' };
      if (insecure) return { ok: true, known: false, isUpdate: false };
      const username = cleanString(msg.username).trim();
      const password = cleanString(msg.password);
      const same = liveEntries().filter((e) => Domain.matches(e.site, pageUrl) && e.username === username);
      return { ok: true, known: same.some((e) => e.password === password), isUpdate: same.length > 0 };
    }
    case 'UPSERT': {
      // "Save password?" banner: may add a login for this site, or update the
      // password of this site's login with the same username — nothing else.
      if (!state) return { ok: false, error: 'locked' };
      touch();
      const username = cleanString(msg.entry?.username).trim();
      const password = cleanString(msg.entry?.password);
      let site = cleanString(msg.entry?.site, 512).trim();
      if (!password) return { ok: false, error: 'empty_password' };
      if (!Domain.matches(site, pageUrl)) site = host;
      const existing = liveEntries().find(
        (e) => Domain.matches(e.site, pageUrl) && e.username === username,
      );
      if (existing) {
        if (existing.password && existing.password !== password) {
          existing.notes = withPreviousPassword(existing.notes, existing.password);
        }
        existing.password = password;
        existing.updatedAt = Date.now();
      } else {
        state.entries.push({
          id: newId(),
          site,
          username,
          password,
          notes: '',
          updatedAt: Date.now(),
          deleted: false,
        });
      }
      const warning = await saveAndUpload();
      return { ok: true, warning };
    }
    case 'PENDING_STASH': {
      const all = await tabStore('pending');
      putRecord(all, tabId, {
        site: pageUrl,
        username: cleanString(msg.username),
        password: cleanString(msg.password),
        ts: Date.now(),
        shows: 0,
      });
      await saveTabStore('pending', all);
      return { ok: true };
    }
    case 'PENDING_TAKE': {
      const all = await tabStore('pending');
      const p = findRecord(all, tabId, pageUrl);
      let pending = null;
      if (p && p.shows >= PENDING_MAX_SHOWS) {
        dropRecords(all, tabId, pageUrl);
      } else if (reachable(p)) {
        p.shows += 1;
        pending = { site: host, username: p.username, password: p.password };
      }
      await saveTabStore('pending', all);
      return { ok: true, pending };
    }
    case 'PENDING_CLEAR': {
      const all = await tabStore('pending');
      dropRecords(all, tabId, pageUrl);
      await saveTabStore('pending', all);
      return { ok: true };
    }
    case 'ID_REMEMBER': {
      const value = cleanString(msg.value, 320).trim();
      if (!value) return { ok: true };
      const all = await tabStore('identifiers');
      putRecord(all, tabId, { site: pageUrl, value, ts: Date.now() });
      await saveTabStore('identifiers', all);
      return { ok: true };
    }
    case 'ID_GET': {
      const r = findRecord(await tabStore('identifiers'), tabId, pageUrl);
      return { ok: true, value: reachable(r) ? r.value : '' };
    }
    default:
      // UNLOCK, DELETE, SYNC, full-vault LIST, ... are popup-only.
      throw new Forbidden();
  }
}

// Requests from the extension's own popup.
async function handleExtensionMessage(msg) {
  switch (msg.type) {
    case 'STATUS':
      return { ok: true, locked: !state, connected: await drive.isSignedIn() };
    case 'REDIRECT_URL':
      return { ok: true, url: drive.redirectUrl() };
    case 'CONNECT':
      await drive.signIn();
      return { ok: true };
    case 'DISCONNECT':
      await drive.signOut();
      await lock();
      return { ok: true };
    case 'VAULT_EXISTS':
      return { ok: true, exists: Boolean(await drive.download()) };
    case 'UNLOCK':
      return { ok: true, warning: await actionUnlock(cleanString(msg.password, 1024)) };
    case 'CREATE': {
      const password = cleanString(msg.password, 1024);
      if (password.length < MIN_MASTER_LENGTH) return { ok: false, error: 'too_short' };
      // Never overwrite a vault another device created in the meantime.
      if (await drive.download()) return { ok: false, error: 'vault_exists' };
      return { ok: true, warning: await actionCreate(password) };
    }
    case 'LOCK':
      await lock();
      return { ok: true };
    case 'LIST': {
      if (!state) return { ok: false, error: 'locked' };
      touch();
      return { ok: true, entries: summary(liveEntries()) };
    }
    case 'REVEAL': {
      if (!state) return { ok: false, error: 'locked' };
      touch();
      const e = liveEntries().find((x) => x.id === msg.id);
      if (!e) return { ok: false, error: 'not_found' };
      return { ok: true, username: e.username, password: e.password };
    }
    case 'UPSERT': {
      if (!state) return { ok: false, error: 'locked' };
      touch();
      const src = msg.entry || {};
      const id = typeof src.id === 'string' && src.id ? src.id : newId();
      const i = state.entries.findIndex((x) => x.id === id);
      const prev = i >= 0 ? state.entries[i] : {};
      // Start from the stored entry so fields the popup doesn't edit (notes,
      // anything newer app versions add) survive an edit.
      const e = {
        ...prev,
        id,
        site: cleanString(src.site, 512).trim(),
        username: cleanString(src.username).trim(),
        password: cleanString(src.password),
        notes: src.notes === undefined ? prev.notes || '' : cleanString(src.notes, 8192),
        updatedAt: Date.now(),
        deleted: false,
      };
      if (i >= 0) state.entries[i] = e;
      else state.entries.push(e);
      return { ok: true, id: e.id, warning: await saveAndUpload() };
    }
    case 'DELETE': {
      if (!state) return { ok: false, error: 'locked' };
      touch();
      const i = state.entries.findIndex((x) => x.id === msg.id);
      if (i >= 0) {
        state.entries[i] = {
          ...state.entries[i],
          site: '',
          username: '',
          password: '',
          notes: '',
          deleted: true,
          updatedAt: Date.now(),
        };
        return { ok: true, warning: await saveAndUpload() };
      }
      return { ok: true };
    }
    case 'SYNC': {
      if (!state) return { ok: false, error: 'locked' };
      touch();
      try {
        return { ok: true, message: await sync() };
      } catch (e) {
        if (e.message === 'SYNC_PASSWORD_MISMATCH') return { ok: false, error: 'password_mismatch' };
        // Stays unlocked: locking here used to drop changes that hadn't
        // reached Drive yet. Unlocking again takes them along.
        if (e.message === 'NEEDS_UNLOCK') return { ok: false, error: 'needs_unlock' };
        return { ok: false, error: String(e.message || e) };
      }
    }
    case 'GENERATE':
      return { ok: true, password: generatePassword(msg.length) };
    case 'CLIPBOARD_CLEAR_LATER':
      await scheduleClipboardClear();
      return { ok: true };
    default:
      return { ok: false, error: 'unknown_message' };
  }
}

api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || typeof msg !== 'object' || msg.target === 'offscreen') return false;
  if (sender.id !== api.runtime.id) return false;
  const fromExtension = (sender.url || '').startsWith(EXT_ORIGIN);
  (async () => {
    await restoreSession();
    return fromExtension ? handleExtensionMessage(msg) : handlePageMessage(msg, sender);
  })()
    .then(sendResponse)
    .catch((e) => {
      if (e instanceof Forbidden) sendResponse({ ok: false, error: 'forbidden' });
      else if (e instanceof WrongPasswordError) sendResponse({ ok: false, error: 'wrong_password' });
      else if (e instanceof CorruptVaultError) sendResponse({ ok: false, error: 'corrupt_vault' });
      else sendResponse({ ok: false, error: String(e?.message || e) });
    });
  return true; // keep the channel open for the async response
});

// Periodic idle check so a forgotten, unattended browser doesn't stay
// unlocked forever; also the backstop for the clipboard clear.
api.alarms.create('idle-check', { periodInMinutes: 1 });
api.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name === 'clipboard-clear') {
    const { clipboardClearAt } = await api.storage.session.get('clipboardClearAt');
    if (clipboardClearAt && Date.now() >= clipboardClearAt - 1000) await clearClipboardNow();
    return;
  }
  if (alarm.name === 'sync-retry') {
    await restoreSession();
    const unsynced = await getUnsynced();
    if (!state || !unsynced) return; // merged on the next unlock instead
    await sync().catch(() => api.alarms.create('sync-retry', { delayInMinutes: 5 }));
    return;
  }
  if (alarm.name !== 'idle-check') return;
  await restoreSession();
  if (state && Date.now() - lastActivity > IDLE_LIMIT_MS) await lock();
});
