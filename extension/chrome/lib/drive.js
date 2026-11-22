// Talks to the same hidden Drive file (vault.kasa, in appDataFolder) the
// desktop/mobile Kasa app uses.
//
// Primary path: chrome.identity.getAuthToken, using the signed-in browser
// profile's Google account — no extra sign-in screen. Chrome supports this.
//
// Fallback: Microsoft Edge does NOT implement getAuthToken ("This API is
// not supported on Microsoft Edge") even though it's otherwise Chromium.
// When that's detected, this switches — once, and remembered for the rest
// of the session — to chrome.identity.launchWebAuthFlow with PKCE against
// the same "Web client 1" OAuth client the Firefox build uses, which Edge
// does support.
import { webClientId, webClientSecret } from './config.js';
import { kvGet, kvSet, kvDelete } from './kv.js';

const FILE_NAME = 'vault.kasa';
const SCOPE = 'https://www.googleapis.com/auth/drive.appdata';

// Same language rule as the rest of the extension: Turkish for a Turkish
// browser, English otherwise. These messages reach the popup as they are.
const isTr = /^tr\b/i.test((globalThis.browser ?? globalThis.chrome).i18n?.getUILanguage?.() || navigator.language || '');
const t = (tr, en) => (isTr ? tr : en);

// Longest one Google request may take. A stalled connection used to leave
// the popup waiting ("Saving…") with no end.
const REQUEST_TIMEOUT_MS = 30000;

function request(url, options = {}) {
  return fetch(url, { ...options, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) }).catch((e) => {
    if (e?.name !== 'TimeoutError') throw e;
    throw new Error(t('Google yanıt vermedi; bağlantını kontrol edip tekrar dene.', "Google didn't respond; check your connection and try again."));
  });
}

function isUnsupportedError(e) {
  return /not supported/i.test(e?.message || '');
}

export function redirectUrl() {
  return chrome.identity.getRedirectURL();
}

let useFallback = false;

// ---------------------------------------------------------- primary (Chrome)

function getToken(interactive) {
  return new Promise((resolve, reject) => {
    chrome.identity.getAuthToken({ interactive }, (token) => {
      if (chrome.runtime.lastError || !token) {
        reject(new Error(chrome.runtime.lastError?.message || t('Giriş yapılamadı.', "Couldn't sign in.")));
      } else {
        resolve(token);
      }
    });
  });
}

function removeCachedToken(token) {
  return new Promise((resolve) => chrome.identity.removeCachedAuthToken({ token }, resolve));
}

// --------------------------------------------------------- fallback (Edge)

function b64url(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function randomString(n) {
  return b64url(crypto.getRandomValues(new Uint8Array(n)));
}

// The refresh token lives in the extension's own IndexedDB (lib/kv.js),
// which content scripts can't reach — not in storage.local, which they can.
// A token left in storage.local by an older version is moved over once.
async function getRefreshToken() {
  const token = await kvGet('refreshToken');
  if (token) return token;
  const { refreshToken: legacy } = await chrome.storage.local.get('refreshToken');
  if (!legacy) return null;
  await kvSet('refreshToken', legacy);
  await chrome.storage.local.remove('refreshToken');
  return legacy;
}

async function setRefreshToken(token) {
  if (token) await kvSet('refreshToken', token);
  else await kvDelete('refreshToken');
  await chrome.storage.local.remove('refreshToken');
}

let cachedAccess = null;
let cachedExpiry = 0;

async function accessTokenFallback() {
  if (cachedAccess && Date.now() < cachedExpiry) return cachedAccess;
  const refreshToken = await getRefreshToken();
  if (!refreshToken) throw new Error(t('Google hesabı bağlı değil.', 'No Google account is connected.'));
  const res = await request('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: webClientId,
      client_secret: webClientSecret,
      refresh_token: refreshToken,
      grant_type: 'refresh_token',
    }),
  });
  const j = await res.json().catch(() => ({}));
  if (!res.ok) {
    // Revoked or expired for good: forget it, so the popup offers the Google
    // step again instead of asking for the master password forever.
    if (j.error === 'invalid_grant') await setRefreshToken(null);
    throw new Error(`${t('Oturum yenilenemedi, yeniden bağlanın.', "Couldn't renew the session; connect again.")} (${j.error || res.status})`);
  }
  cachedAccess = j.access_token;
  cachedExpiry = Date.now() + (j.expires_in - 60) * 1000;
  return cachedAccess;
}

async function signInFallback() {
  const redirect = chrome.identity.getRedirectURL();
  const verifier = randomString(48);
  const challenge = b64url(
    new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))),
  );
  const state = randomString(16);

  const authUrl = new URL('https://accounts.google.com/o/oauth2/v2/auth');
  authUrl.search = new URLSearchParams({
    client_id: webClientId,
    redirect_uri: redirect,
    response_type: 'code',
    scope: SCOPE,
    code_challenge: challenge,
    code_challenge_method: 'S256',
    access_type: 'offline',
    prompt: 'consent',
    state,
  }).toString();

  const resultUrl = await chrome.identity.launchWebAuthFlow({
    url: authUrl.toString(),
    interactive: true,
  });
  const q = new URL(resultUrl).searchParams;
  if (q.get('state') !== state) throw new Error(t('Google girişi doğrulanamadı (state).', "Couldn't verify the Google sign-in (state)."));
  const code = q.get('code');
  if (!code) throw new Error(q.get('error') || t('Google girişi iptal edildi.', 'The Google sign-in was cancelled.'));

  const tRes = await request('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      code,
      client_id: webClientId,
      client_secret: webClientSecret,
      redirect_uri: redirect,
      grant_type: 'authorization_code',
      code_verifier: verifier,
    }),
  });
  const tJson = await tRes.json();
  if (!tRes.ok || !tJson.refresh_token) {
    throw new Error(`${t('Google token alınamadı', "Couldn't get a Google token")}: ${tJson.error || tRes.status}`);
  }
  await setRefreshToken(tJson.refresh_token);
  cachedAccess = tJson.access_token;
  cachedExpiry = Date.now() + (tJson.expires_in - 60) * 1000;
}

async function signOutFallback() {
  const refreshToken = await getRefreshToken();
  if (refreshToken) {
    await request(`https://oauth2.googleapis.com/revoke?token=${refreshToken}`, {
      method: 'POST',
    }).catch(() => {});
  }
  await setRefreshToken(null);
  cachedAccess = null;
}

// ------------------------------------------------------------------ shared

export async function isSignedIn() {
  if (useFallback) return (await getRefreshToken()) != null;
  try {
    await getToken(false);
    return true;
  } catch (e) {
    if (isUnsupportedError(e)) {
      useFallback = true;
      return (await getRefreshToken()) != null;
    }
    return false;
  }
}

export async function signIn() {
  if (useFallback) return signInFallback();
  try {
    await getToken(true);
  } catch (e) {
    if (!isUnsupportedError(e)) throw e;
    useFallback = true;
    return signInFallback();
  }
}

export async function signOut() {
  if (useFallback) return signOutFallback();
  try {
    const token = await getToken(false);
    await removeCachedToken(token);
    await request(`https://accounts.google.com/o/oauth2/revoke?token=${token}`);
  } catch {
    /* not signed in */
  }
}

async function authedFetch(url, options, retry = true) {
  const token = useFallback ? await accessTokenFallback() : await getToken(true);
  const res = await request(url, {
    ...options,
    headers: { ...(options?.headers || {}), Authorization: `Bearer ${token}` },
  });
  if (res.status === 401 && retry && !useFallback) {
    await removeCachedToken(token);
    return authedFetch(url, options, false);
  }
  return res;
}

async function findFileId() {
  const url =
    'https://www.googleapis.com/drive/v3/files?' +
    new URLSearchParams({
      spaces: 'appDataFolder',
      q: `name = '${FILE_NAME}'`,
      fields: 'files(id)',
    });
  const res = await authedFetch(url);
  if (!res.ok) throw new Error(`${t('Drive hatası', 'Drive error')} (${res.status})`);
  const j = await res.json();
  return j.files?.[0]?.id ?? null;
}

export async function download() {
  const id = await findFileId();
  if (!id) return null;
  const res = await authedFetch(
    `https://www.googleapis.com/drive/v3/files/${id}?alt=media`,
  );
  if (!res.ok) throw new Error(`${t('Drive hatası', 'Drive error')} (${res.status})`);
  return new Uint8Array(await res.arrayBuffer());
}

export async function upload(bytes) {
  const id = await findFileId();
  if (id) {
    const res = await authedFetch(
      `https://www.googleapis.com/upload/drive/v3/files/${id}?uploadType=media`,
      { method: 'PATCH', headers: { 'Content-Type': 'application/octet-stream' }, body: bytes },
    );
    if (!res.ok) throw new Error(`${t('Drive hatası', 'Drive error')} (${res.status})`);
    return;
  }
  const boundary = 'kasa-ext-boundary';
  const meta = JSON.stringify({ name: FILE_NAME, parents: ['appDataFolder'] });
  const body =
    `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${meta}\r\n` +
    `--${boundary}\r\nContent-Type: application/octet-stream\r\n\r\n`;
  const tail = `\r\n--${boundary}--`;
  const parts = [
    new TextEncoder().encode(body),
    bytes,
    new TextEncoder().encode(tail),
  ];
  const total = parts.reduce((n, p) => n + p.length, 0);
  const combined = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    combined.set(p, off);
    off += p.length;
  }
  const res = await authedFetch(
    'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart',
    {
      method: 'POST',
      headers: { 'Content-Type': `multipart/related; boundary=${boundary}` },
      body: combined,
    },
  );
  if (!res.ok) throw new Error(`${t('Drive hatası', 'Drive error')} (${res.status})`);
}
