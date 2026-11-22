// Talks to the same hidden Drive file (vault.kasa, in appDataFolder) the
// desktop/mobile Kasa app and the Chrome/Edge extension use.
//
// Firefox has no chrome.identity.getAuthToken equivalent, so this uses
// browser.identity.launchWebAuthFlow: it opens Google's sign-in page and
// waits for it to redirect back to this extension's own redirect URL
// (browser.identity.getRedirectURL(), https://<sha1 of the add-on id>.
// extensions.allizom.org/ — the same on every install of this add-on id).
// It has to be registered once, by hand, as an authorized redirect URI on
// the "Web client 1" OAuth client in Google Cloud Console; the popup's
// "yönlendirme adresini göster" button prints it.
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

// Firefox for Android has no identity API, so no Google sign-in there.
const hasIdentity = () => typeof browser.identity?.launchWebAuthFlow === 'function';

export function redirectUrl() {
  return hasIdentity() ? browser.identity.getRedirectURL() : '';
}

// The refresh token lives in the extension's own IndexedDB (lib/kv.js),
// which content scripts can't reach — not in storage.local, which they can.
// A token left in storage.local by an older version is moved over once.
async function getRefreshToken() {
  const token = await kvGet('refreshToken');
  if (token) return token;
  const { refreshToken: legacy } = await browser.storage.local.get('refreshToken');
  if (!legacy) return null;
  await kvSet('refreshToken', legacy);
  await browser.storage.local.remove('refreshToken');
  return legacy;
}

async function setRefreshToken(token) {
  if (token) await kvSet('refreshToken', token);
  else await kvDelete('refreshToken');
  await browser.storage.local.remove('refreshToken');
}

let cachedAccess = null;
let cachedExpiry = 0;

async function accessToken() {
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

export async function isSignedIn() {
  return (await getRefreshToken()) != null;
}

function b64url(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function randomString(n) {
  return b64url(crypto.getRandomValues(new Uint8Array(n)));
}

export async function signIn() {
  if (!hasIdentity()) {
    throw new Error(
      t(
        'Bu tarayıcı Google ile bağlanmayı desteklemiyor (Android için Firefox). Passlune’u bilgisayardaki Firefox’ta ya da Passlune Android uygulamasında kullanın.',
        "This browser can't connect to Google (Firefox for Android). Use Passlune in Firefox on a computer, or the Passlune Android app.",
      ),
    );
  }
  const redirect = redirectUrl();
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

  let resultUrl;
  try {
    resultUrl = await browser.identity.launchWebAuthFlow({
      url: authUrl.toString(),
      interactive: true,
    });
  } catch (e) {
    throw new Error(
      t(
        `Google girişi başarısız. Bu Firefox profilinin yönlendirme adresi (${redirect}) ` +
          `Google Cloud Console'daki "Web client 1" istemcisine yetkili yönlendirme adresi olarak eklenmemiş olabilir.`,
        `The Google sign-in failed. This Firefox profile's redirect address (${redirect}) may not be ` +
          `an authorized redirect URI of the "Web client 1" client in Google Cloud Console.`,
      ) + ` (${e.message || e})`,
    );
  }
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

export async function signOut() {
  const refreshToken = await getRefreshToken();
  if (refreshToken) {
    await request(`https://oauth2.googleapis.com/revoke?token=${refreshToken}`, {
      method: 'POST',
    }).catch(() => {});
  }
  await setRefreshToken(null);
  cachedAccess = null;
}

async function authedFetch(url, options) {
  const token = await accessToken();
  return request(url, {
    ...options,
    headers: { ...(options?.headers || {}), Authorization: `Bearer ${token}` },
  });
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
  const parts = [new TextEncoder().encode(body), bytes, new TextEncoder().encode(tail)];
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
