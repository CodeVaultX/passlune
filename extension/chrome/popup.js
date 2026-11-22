import './lib/psl-data.js';
import './lib/domain.js';

const api = globalThis.browser ?? globalThis.chrome;
// UI language: Turkish when the browser is set to Turkish, English otherwise.
const isTr = /^tr\b/i.test(api.i18n?.getUILanguage?.() || navigator.language || '');
const t = (tr, en) => (isTr ? tr : en);
const Domain = globalThis.KasaDomain;
const ICON = {"fill":"<svg viewBox=\"0 0 24 24\" width=\"17\" height=\"17\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4\"/><path d=\"M10 17l5-5-5-5\"/><path d=\"M15 12H3\"/></svg>","user":"<svg viewBox=\"0 0 24 24\" width=\"17\" height=\"17\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"8\" r=\"4\"/><path d=\"M4 21c0-4 4-6 8-6s8 2 8 6\"/></svg>","key":"<svg viewBox=\"0 0 24 24\" width=\"17\" height=\"17\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"7.5\" cy=\"15.5\" r=\"4.5\"/><path d=\"M10.7 12.3L21 2\"/><path d=\"M16 7l3 3\"/><path d=\"M14 9l2 2\"/></svg>","edit":"<svg viewBox=\"0 0 24 24\" width=\"17\" height=\"17\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M12 20h9\"/><path d=\"M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z\"/></svg>","del":"<svg viewBox=\"0 0 24 24\" width=\"17\" height=\"17\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M3 6h18\"/><path d=\"M8 6V4h8v2\"/><path d=\"M19 6l-1 14H6L5 6\"/></svg>"};
const LOGO = '<svg class="logo" viewBox="0 0 100 100" aria-hidden="true"><defs><mask id="pl-m"><rect width="100" height="100" fill="#fff"/><circle cx="64" cy="41" r="25" fill="#000"/><circle cx="32" cy="47" r="5" fill="#000"/><polygon points="29.5,49 34.5,49 36,61 28,61" fill="#000"/></mask></defs><circle cx="50" cy="50" r="44" fill="none" stroke="#e8b04b" stroke-opacity=".55" stroke-width="3"/><circle cx="47" cy="50" r="31" fill="#e8b04b" mask="url(#pl-m)"/></svg>';
const app = document.getElementById('app');

function send(msg) {
  return Promise.resolve(api.runtime.sendMessage(msg))
    .then((res) => res || { ok: false, error: 'no_response' })
    .catch((e) => ({ ok: false, error: String(e?.message || e) }));
}

// Every value interpolated into the templates below goes through esc():
// entry sites and usernames come from pages and from synced devices, so they
// must never be able to inject markup into the extension's own page.
function esc(s) {
  return String(s ?? '').replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );
}

function h(html) {
  const doc = new DOMParser().parseFromString(html.trim(), 'text/html');
  return document.importNode(doc.body.firstElementChild, true);
}

async function activeTab() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function currentTabUrl() {
  const tab = await activeTab();
  return /^https?:/i.test(tab?.url || '') ? tab.url : '';
}

function isInsecurePage(url) {
  if (!/^http:/i.test(url)) return false;
  return !Domain.isPrivateHost(Domain.hostOf(url));
}

// Fills the current tab's best-guess username/password fields directly from
// the popup — works even on pages like Google's, where the email step has
// no password field yet (or on a page the content script hasn't attached
// its own picker to for any other reason).
function pageFillFunction(username, password, expectedOrigin) {
  // The page may have navigated while a confirm() dialog was open: never
  // fill a document other than the one the user approved.
  if (expectedOrigin && location.origin !== expectedOrigin) return 'moved';
  function setValue(el, value) {
    const proto = window.HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
    setter ? setter.call(el, value) : (el.value = value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }
  // Same heuristics as content.js (duplicated on purpose: this function is
  // serialized and injected into the page, so it can't call anything
  // outside itself). Keyword hints first, including Turkish ones like
  // "T.C. Kimlik No"; failing that, the nearest plain text field before the
  // password field.
  function hintOf(el) {
    const label = [...(el.labels || [])].map((l) => l.textContent).join(' ');
    return `${el.name} ${el.id} ${el.autocomplete} ${el.placeholder} ${el.getAttribute('aria-label') || ''} ${label}`
      .toLowerCase()
      .replace(/̇/g, '');
  }
  function isVisible(el) {
    return el.offsetParent !== null || el.getClientRects().length > 0;
  }
  function isIdentifierCandidate(el) {
    if (el.tagName !== 'INPUT' || el.disabled) return false;
    const t = (el.type || 'text').toLowerCase();
    if (!['text', 'email', 'tel', 'number'].includes(t)) return false;
    return isVisible(el);
  }
  function isUsernameField(el) {
    if (!isIdentifierCandidate(el)) return false;
    return (
      el.autocomplete === 'username' ||
      el.type === 'email' ||
      /user|e-?mail|login|kullan[ıi]c[ıi]|kimlik|tckn|\btc\b|t\.c\.|hesap|account|phone|telefon|gsm/.test(hintOf(el))
    );
  }
  // Masked fields that aren't account passwords (API keys, OTP, card codes)
  // never receive a login password.
  function isSecretField(el) {
    const ac = (el.autocomplete || '').toLowerCase();
    if (ac === 'one-time-code' || ac.startsWith('cc-')) return true;
    if (ac === 'current-password' || ac === 'new-password') return false;
    return /api|token|secret|\bkey\b|[-_ ]key|key[-_ ]|apikey|anahtar|bearer|webhook|otp|one.?time|2fa|totp|mfa|\bpin\b|cvv|cvc|\bcard|kart|iban/.test(
      hintOf(el),
    );
  }
  const pw = [...document.querySelectorAll('input[type="password"]')].find(
    (el) => isVisible(el) && !isSecretField(el),
  );
  if (pw) {
    const form = pw.closest('form') || document;
    const inputs = [...form.querySelectorAll('input')];
    const idx = inputs.indexOf(pw);
    let userField = null;
    for (let i = idx - 1; i >= 0 && !userField; i--) {
      if (isUsernameField(inputs[i])) userField = inputs[i];
    }
    if (!userField) userField = inputs.find((i) => i !== pw && isUsernameField(i));
    for (let i = idx - 1; i >= 0 && !userField; i--) {
      if (isIdentifierCandidate(inputs[i])) userField = inputs[i];
    }
    if (userField) setValue(userField, username);
    setValue(pw, password);
    return userField ? 'both' : 'password';
  }
  const candidate =
    [...document.querySelectorAll('input')].find(isUsernameField) ||
    [...document.querySelectorAll('input')].find(isIdentifierCandidate);
  if (candidate) {
    setValue(candidate, username);
    return 'username';
  }
  return 'none';
}

async function fillIntoActiveTab(entry) {
  const tab = await activeTab();
  if (!tab?.id) return { ok: false, error: 'no_tab' };
  const url = /^https?:/i.test(tab.url || '') ? tab.url : '';
  if (!url) return { ok: false, error: t('Bu sayfaya doldurulamaz', "Can't fill this page") };
  // The popup can fill any entry into any page — so make sure the user
  // means it when the page isn't the entry's site (a look-alike domain is
  // exactly how phishing gets a password typed in).
  if (!Domain.matches(entry.site, url)) {
    const ok = confirm(
      t(
        `Bu kayıt "${entry.site}" için, ama açık sayfa "${Domain.hostOf(url)}".\n\nŞifre bu sayfaya doldurulsun mu? Emin değilseniz Vazgeç’e basın.`,
        `This login is for "${entry.site}", but the open page is "${Domain.hostOf(url)}".\n\nFill the password into this page? If you're not sure, press Cancel.`,
      ),
    );
    if (!ok) return { ok: false, error: 'cancelled' };
  }
  if (isInsecurePage(url)) {
    const ok = confirm(
      t(
        'Bu sayfa şifrelenmemiş (http). Şifre ağ üzerinde açık gönderilebilir.\n\nYine de doldurulsun mu?',
        'This page is not encrypted (http). The password could be sent over the network in the clear.\n\nFill it anyway?',
      ),
    );
    if (!ok) return { ok: false, error: 'cancelled' };
  }
  const rev = await send({ type: 'REVEAL', id: entry.id });
  if (!rev.ok) return rev;
  const [{ result } = {}] = await api.scripting.executeScript({
    target: { tabId: tab.id },
    func: pageFillFunction,
    args: [rev.username, rev.password, new URL(url).origin],
  });
  if (result === 'moved') return { ok: false, error: t('Sayfa değişti, doldurulmadı', 'The page changed; nothing was filled') };
  return { ok: true, result };
}

async function main() {
  const status = await send({ type: 'STATUS' });
  if (!status.ok) return renderError(t('Uzantı ile iletişim kurulamadı.', "Couldn't reach the extension."));
  if (!status.connected) return renderConnect();
  if (status.locked) return renderLockedOrCreate();
  return renderList();
}

/** Locked: unlock the vault on Drive, or create one if there is none yet. */
async function renderLockedOrCreate(notice) {
  app.replaceChildren(h(`<div><h1>${LOGO} Passlune</h1><p class="hint">${t('Drive kontrol ediliyor…', 'Checking Drive…')}</p></div>`));
  const res = await send({ type: 'VAULT_EXISTS' });
  if (res.ok && !res.exists) return renderCreate();
  if (!res.ok && (await lostGoogle())) return renderConnect(res.error);
  return renderUnlock(notice);
}

// Google refused the saved sign-in and it was forgotten (lib/drive.js): the
// master password can't help until Google is connected again.
async function lostGoogle() {
  const status = await send({ type: 'STATUS' });
  return status.ok && !status.connected;
}

// ---------------------------------------------------------------- create

// First use without the app: there is no vault on Drive yet. The new master
// password is asked twice and must be at least 10 characters, like the app.
function renderCreate() {
  app.replaceChildren(
    h(`
    <div>
      <h1>${LOGO} ${t('Yeni kasa oluştur', 'Create a new vault')}</h1>
      <p class="hint">${t(
        "Google Drive'ında henüz bir Passlune kasası yok. Bir ana şifre belirle; kasan bu şifreyle cihazında şifrelenip Drive'ına yüklenir. Telefon ve bilgisayardaki Passlune uygulaması da aynı kasayı bu şifreyle açar.",
        "There's no Passlune vault in your Google Drive yet. Choose a master password: your vault is encrypted with it on this device and uploaded to your Drive. The Passlune apps for phone and computer open the same vault with it.",
      )}</p>
      <label>${t('Ana şifre (en az 10 karakter)', 'Master password (at least 10 characters)')}</label>
      <input type="password" id="pw" autofocus autocomplete="new-password" />
      <label>${t('Ana şifre (tekrar)', 'Master password (again)')}</label>
      <input type="password" id="pw2" autocomplete="new-password" />
      <p class="hint" style="margin-top:10px">⚠ ${t('Ana şifreyi unutursan kasan kurtarılamaz. Şifre hiçbir yerde saklanmaz.', "If you forget the master password, the vault can't be recovered. It isn't stored anywhere.")}</p>
      <div id="err" class="error" style="display:none"></div>
      <button class="primary" id="go">${t('Kasayı oluştur', 'Create vault')}</button>
    </div>`),
  );
  const pw = document.getElementById('pw');
  const pw2 = document.getElementById('pw2');
  const err = document.getElementById('err');
  const go = document.getElementById('go');
  const fail = (text) => {
    err.style.display = 'block';
    err.textContent = text;
  };
  const submit = async () => {
    if (pw.value.length < 10) return fail(t('Ana şifre en az 10 karakter olmalı.', 'The master password must be at least 10 characters.'));
    if (pw.value !== pw2.value) return fail(t('Şifreler eşleşmiyor.', "The passwords don't match."));
    go.disabled = true;
    go.textContent = t('Oluşturuluyor…', 'Creating…');
    const res = await send({ type: 'CREATE', password: pw.value });
    if (res.ok) return renderList(res.warning);
    go.disabled = false;
    go.textContent = t('Kasayı oluştur', 'Create vault');
    if (res.error === 'vault_exists') return renderUnlock(t('Drive’da bir kasa bulundu; onun ana şifresini girin.', 'A vault was found on Drive; enter its master password.'));
    fail({ too_short: t('Ana şifre en az 10 karakter olmalı.', 'The master password must be at least 10 characters.') }[res.error] || `${t('Oluşturulamadı', "Couldn't create")}: ${res.error}`);
  };
  go.addEventListener('click', submit);
  pw2.addEventListener('keydown', (e) => e.key === 'Enter' && submit());
}

function renderError(msg) {
  app.replaceChildren(h(`<div><p class="error">${esc(msg)}</p></div>`));
}

// -------------------------------------------------------------- connect

// A separate step from unlock, on purpose: bundling the Google sign-in
// inside UNLOCK made failures invisible — Chrome's OAuth consent dialog can
// steal focus and close this popup mid-flow, and the popup would just
// silently reopen back on the same screen with no explanation. Here any
// failure is shown directly on this step, and it never asks for the master
// password until Google is actually connected.
function renderConnect(notice) {
  app.replaceChildren(
    h(`
    <div>
      <h1>${LOGO} Passlune</h1>
      <p class="hint">${t('Kasayı kullanmak için önce Google hesabınızla bağlanın.', 'To use your vault, first connect your Google account.')}</p>
      <button class="primary" id="go">${t('Google ile bağlan', 'Connect with Google')}</button>
      <div id="err" class="error" style="display:none"></div>
      <div id="area"></div>
      <button class="link-btn" id="showUrl" style="margin-top:10px">
        ${t('Bu tarayıcının yönlendirme adresini göster', "Show this browser's redirect address")}
      </button>
    </div>`),
  );
  const go = document.getElementById('go');
  const err = document.getElementById('err');
  if (notice) {
    err.style.display = 'block';
    err.textContent = notice;
  }
  go.addEventListener('click', async () => {
    go.disabled = true;
    go.textContent = t('Bağlanılıyor…', 'Connecting…');
    const res = await send({ type: 'CONNECT' });
    if (res.ok) return renderLockedOrCreate();
    go.disabled = false;
    go.textContent = t('Google ile bağlan', 'Connect with Google');
    err.style.display = 'block';
    err.textContent = `${t('Bağlanılamadı', "Couldn't connect")}: ${res.error}`;
  });
  document.getElementById('showUrl').addEventListener('click', async () => {
    const res = await send({ type: 'REDIRECT_URL' });
    const area = document.getElementById('area');
    area.replaceChildren(
      h(`
        <div style="margin-top:8px">
          <p class="hint">${t(
            'Bu adresi Google Cloud Console’daki "Web client 1" istemcisinin yetkili yönlendirme adreslerine ekletin:',
            'Have this address added to the authorized redirect URIs of the "Web client 1" client in Google Cloud Console:',
          )}</p>
          <input type="text" readonly id="redirectUrl" />
        </div>`),
    );
    const input = document.getElementById('redirectUrl');
    input.value = res.url || '';
    input.addEventListener('focus', () => input.select());
    input.addEventListener('click', () => input.select());
  });
}

// --------------------------------------------------------------- unlock

function renderUnlock(notice) {
  app.replaceChildren(
    h(`
    <div>
      <h1>${LOGO} ${t('Passlune kilitli', 'Passlune is locked')}</h1>
      <p class="hint">${t('Google hesabınızla senkronlanan kasanın ana şifresi.', 'The master password of the vault synced with your Google account.')}</p>
      <label>${t('Ana şifre', 'Master password')}</label>
      <input type="password" id="pw" autofocus />
      <div id="err" class="error" style="display:none"></div>
      <button class="primary" id="go">${t('Devam et', 'Continue')}</button>
    </div>`),
  );
  const pw = document.getElementById('pw');
  const err = document.getElementById('err');
  const go = document.getElementById('go');
  if (notice) {
    err.style.display = 'block';
    err.textContent = notice;
  }
  const submit = async () => {
    if (!pw.value) return;
    go.disabled = true;
    go.textContent = t('Bağlanılıyor…', 'Connecting…');
    const res = await send({ type: 'UNLOCK', password: pw.value });
    if (res.ok) return renderList(res.warning);
    if (res.error === 'no_vault') return renderCreate();
    if (await lostGoogle()) return renderConnect(res.error);
    go.disabled = false;
    go.textContent = t('Devam et', 'Continue');
    err.style.display = 'block';
    err.textContent =
      {
        wrong_password: t('Yanlış ana şifre.', 'Wrong master password.'),
        corrupt_vault: t('Kasa dosyası okunamadı.', "Couldn't read the vault file."),
      }[res.error] || `${t('Bağlanılamadı', "Couldn't connect")}: ${res.error}`;
  };
  go.addEventListener('click', submit);
  pw.addEventListener('keydown', (e) => e.key === 'Enter' && submit());
}

// ----------------------------------------------------------------- list

// [notice]: shown in the status line, e.g. a change that is only on this
// device until Drive can be reached.
async function renderList(notice) {
  const tabUrl = await currentTabUrl();
  const res = await send({ type: 'LIST' });
  if (!res.ok) return renderUnlock();
  const entries = res.entries;

  app.replaceChildren(
    h(`
    <div>
      <div class="topbar">
        <h1>${LOGO} Passlune</h1>
        <div class="row">
          <button class="icon-btn" id="sync" title="${t('Senkronize et', 'Sync')}">⟳</button>
          <button class="icon-btn" id="menu" title="${t('Menü', 'Menu')}">⋮</button>
        </div>
      </div>
      ${
        tabUrl && isInsecurePage(tabUrl)
          ? `<p class="error" style="margin:6px 0">⚠ ${t('Bu sayfa şifrelenmemiş (http).', 'This page is not encrypted (http).')}</p>`
          : ''
      }
      <input type="search" id="q" placeholder="${t('Site veya kullanıcı ara', 'Search sites or usernames')}" />
      <button class="link-btn" id="toggleAll" style="display:none">${t('Tüm kayıtları göster', 'Show all logins')}</button>
      <ul class="entries" id="list"></ul>
      <button class="primary" id="add">+ ${t('Yeni kayıt', 'New login')}</button>
      <div class="status" id="status"></div>
    </div>`),
  );

  // Registrable-domain match (lib/domain.js): accounts.google.com and
  // mail.google.com both match a google.com entry; garanti.com.tr never
  // matches some-other-site.com.tr; IPs and localhost match exactly.
  const matchesHost = (e) => Boolean(tabUrl) && Domain.matches(e.site, tabUrl);

  let showAll = false;
  const listEl = document.getElementById('list');
  function draw(filter) {
    const f = (filter || '').toLowerCase();
    const bySite = tabUrl && !f && !showAll ? entries.filter(matchesHost) : entries;
    const shown = bySite
      .filter((e) => e.site.toLowerCase().includes(f) || e.username.toLowerCase().includes(f))
      .sort((a, b) => Number(matchesHost(b)) - Number(matchesHost(a)));
    listEl.replaceChildren(
      ...shown.map((e) => {
        const li = h(`
          <li>
            <div class="entry-main">
              <div class="entry-site"><span class="t">${esc(e.site)}</span>${matchesHost(e) ? `<span class="here">${t('bu site', 'this site')}</span>` : ''}</div>
              <div class="entry-user">${esc(e.username)}</div>
            </div>
            <div class="entry-actions">
              <button title="${t('Sayfaya doldur', 'Fill into page')}" data-a="fill" class="act-fill">${ICON.fill}</button>
              <button title="${t('Kullanıcı adını kopyala', 'Copy username')}" data-a="copyuser">${ICON.user}</button>
              <button title="${t('Şifreyi kopyala', 'Copy password')}" data-a="copypass">${ICON.key}</button>
              <button title="${t('Düzenle', 'Edit')}" data-a="edit">${ICON.edit}</button>
              <button title="${t('Sil', 'Delete')}" data-a="del" class="act-del">${ICON.del}</button>
            </div>
          </li>`);
        li.querySelector('[data-a=fill]').addEventListener('click', async () => {
          const res = await fillIntoActiveTab(e);
          const st = document.getElementById('status');
          if (res.error === 'cancelled') return;
          if (st) {
            st.textContent = res.ok
              ? res.result === 'username'
                ? t('Kullanıcı adı dolduruldu (şifre alanı bu sayfada yok)', 'Username filled (no password field on this page)')
                : t('Sayfaya dolduruldu', 'Filled into the page')
              : `${t('Doldurulamadı', "Couldn't fill")}: ${res.error}`;
          }
          if (res.ok) window.close();
        });
        li.querySelector('[data-a=copyuser]').addEventListener('click', () =>
          copyToClipboard(e.username, false),
        );
        li.querySelector('[data-a=copypass]').addEventListener('click', async () => {
          const rev = await send({ type: 'REVEAL', id: e.id });
          if (rev.ok) copyToClipboard(rev.password, true);
        });
        li.querySelector('[data-a=edit]').addEventListener('click', () => renderEdit(e.id));
        li.querySelector('[data-a=del]').addEventListener('click', async () => {
          if (!confirm(t(`${e.site} silinsin mi?`, `Delete ${e.site}?`))) return;
          const res3 = await send({ type: 'DELETE', id: e.id });
          renderList(res3.warning);
        });
        return li;
      }),
    );
    if (shown.length === 0) {
      const msg = tabUrl && !f && !showAll ? t('Bu site için kayıt yok', 'No logins for this site') : t('Kayıt yok', 'No logins');
      listEl.replaceChildren(h(`<li style="color:#888;justify-content:center">${esc(msg)}</li>`));
    }
    const toggle = document.getElementById('toggleAll');
    if (toggle) {
      toggle.style.display = tabUrl && !document.getElementById('q').value ? '' : 'none';
      toggle.textContent = showAll ? t('Sadece bu siteyi göster', 'Show only this site') : t('Tüm kayıtları göster', 'Show all logins');
    }
  }
  draw('');
  if (notice) document.getElementById('status').textContent = notice;
  document.getElementById('q').addEventListener('input', (e) => draw(e.target.value));
  document.getElementById('toggleAll').addEventListener('click', () => {
    showAll = !showAll;
    draw(document.getElementById('q').value);
  });
  document.getElementById('add').addEventListener('click', () => renderEdit(null));
  document.getElementById('sync').addEventListener('click', async () => {
    const st = document.getElementById('status');
    st.textContent = t('Senkronize ediliyor…', 'Syncing…');
    const res2 = await send({ type: 'SYNC' });
    if (res2.ok) {
      renderList(res2.message);
    } else if (res2.error === 'needs_unlock') {
      renderUnlock(t('Drive’daki kasa yeniden şifrelenmiş; senkron için ana şifreyi tekrar girin.', 'The vault on Drive was re-encrypted; enter the master password again to sync.'));
    } else {
      st.textContent =
        res2.error === 'password_mismatch'
          ? t("Drive'daki kasa farklı bir şifreyle şifrelenmiş.", 'The vault on Drive uses a different master password.')
          : `${t('Senkron başarısız', 'Sync failed')}: ${res2.error}`;
    }
  });
  document.getElementById('menu').addEventListener('click', () => renderMenu());
}

// The popup closes the moment the user clicks into the page to paste, so
// the 20-second clear is scheduled in the background, not here.
async function copyToClipboard(text, secret) {
  const st = document.getElementById('status');
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    if (st) st.textContent = t('Panoya kopyalanamadı', "Couldn't copy to the clipboard");
    return;
  }
  if (secret) await send({ type: 'CLIPBOARD_CLEAR_LATER' });
  if (st) st.textContent = secret ? t('Panoya kopyalandı (20 sn sonra silinecek)', 'Copied (cleared in 20 seconds)') : t('Panoya kopyalandı', 'Copied');
}

// ------------------------------------------------------------------ menu

function renderMenu() {
  app.replaceChildren(
    h(`
    <div>
      <h1>${LOGO} Passlune</h1>
      <button class="secondary" id="back" style="width:100%">← ${t('Geri', 'Back')}</button>
      <button class="secondary" id="lock" style="width:100%;margin-top:8px">${t('Kilitle', 'Lock')}</button>
      <button class="secondary" id="disconnect" style="width:100%;margin-top:8px">${t('Google bağlantısını kes', 'Disconnect Google')}</button>
    </div>`),
  );
  document.getElementById('back').addEventListener('click', () => renderList());
  document.getElementById('lock').addEventListener('click', async () => {
    await send({ type: 'LOCK' });
    renderUnlock();
  });
  document.getElementById('disconnect').addEventListener('click', async () => {
    await send({ type: 'DISCONNECT' });
    renderConnect();
  });
}

// ------------------------------------------------------------------ edit

async function renderEdit(id) {
  const res = await send({ type: 'LIST' });
  const meta = id && res.ok ? res.entries.find((e) => e.id === id) : null;
  let password = '';
  if (id) {
    const rev = await send({ type: 'REVEAL', id });
    if (rev.ok) password = rev.password;
  }

  app.replaceChildren(
    h(`
    <div>
      <h1>${LOGO} ${id ? t('Kaydı düzenle', 'Edit login') : t('Yeni kayıt', 'New login')}</h1>
      <label>Site</label>
      <input type="text" id="site" />
      <label>${t('Kullanıcı adı', 'Username')}</label>
      <input type="text" id="user" />
      <label>${t('Şifre', 'Password')}</label>
      <div class="row">
        <input type="text" id="pass" style="flex:1" />
        <button class="secondary" id="gen" title="${t('Güçlü şifre üret', 'Generate a strong password')}">🎲</button>
      </div>
      <div class="row" style="margin-top:12px">
        <button class="secondary" id="cancel" style="flex:1">${t('Vazgeç', 'Cancel')}</button>
        <button class="primary" id="save" style="flex:1;margin-top:0">${t('Kaydet', 'Save')}</button>
      </div>
    </div>`),
  );
  // Set as properties, so quotes or "<" in a password survive intact.
  document.getElementById('site').value = meta?.site || '';
  document.getElementById('user').value = meta?.username || '';
  document.getElementById('pass').value = password;
  document.getElementById('cancel').addEventListener('click', () => renderList());
  document.getElementById('gen').addEventListener('click', async () => {
    const g = await send({ type: 'GENERATE', length: 18 });
    if (g.ok) document.getElementById('pass').value = g.password;
  });
  document.getElementById('save').addEventListener('click', async () => {
    const entry = {
      id,
      site: document.getElementById('site').value.trim(),
      username: document.getElementById('user').value.trim(),
      password: document.getElementById('pass').value,
      // notes omitted: the background keeps the existing ones.
    };
    if (!entry.site || !entry.username || !entry.password) return;
    const saved = await send({ type: 'UPSERT', entry });
    renderList(saved.ok ? saved.warning : `${t('Kaydedilemedi', "Couldn't save")}: ${saved.error}`);
  });
}

document.documentElement.lang = isTr ? 'tr' : 'en';
main();
