// Runs on every page. Two jobs:
//  1. When a login form is found and the vault has matching entries, show a
//     small "pick a saved login" dropdown near the username/password field
//     (one click fills both fields).
//  2. After a form with a password field is submitted, offer to save that
//     login if it isn't already in the vault.
// All rendering happens inside a closed shadow DOM so the host page's CSS
// can't see or clash with it, and decrypted values only ever pass through
// here for the instant it takes to fill the fields.
//
// This script has no storage access of its own: everything goes through the
// background, which decides what this page may see based on the page's
// real URL (not on anything this script claims).

(() => {
  if (window.__kasaContentLoaded) return;
  window.__kasaContentLoaded = true;

  const api = globalThis.browser ?? globalThis.chrome;
  // UI language: Turkish when the browser is set to Turkish, English otherwise.
  const isTr = /^tr\b/i.test(api.i18n?.getUILanguage?.() || navigator.language || '');
  const t = (tr, en) => (isTr ? tr : en);

  // Never rejects: a missing/invalidated extension (e.g. just reloaded)
  // answers like a failed request instead of throwing into the page.
  function send(msg) {
    try {
      return Promise.resolve(api.runtime.sendMessage(msg))
        .then((res) => res || { ok: false, error: 'no_response' })
        .catch(() => ({ ok: false, error: 'unavailable' }));
    } catch {
      return Promise.resolve({ ok: false, error: 'unavailable' });
    }
  }

  // The content script now runs at document_start (see manifest.json) so it
  // has the best possible chance of reading the pending-save stash before a
  // fast redirect fires — but that means <body> may not exist yet whenever
  // we actually try to render something.
  function whenBodyReady(fn) {
    if (document.body) return fn();
    document.addEventListener('DOMContentLoaded', () => fn(), { once: true });
  }

  let host = null; // shadow host element, one at a time
  let hostIsPicker = false;
  let hostAnchor = null; // the field the picker belongs to
  let hostCleanup = null;
  function closeUI() {
    hostCleanup?.();
    hostCleanup = null;
    host?.remove();
    host = null;
    hostAnchor = null;
  }
  // A click elsewhere closes the picker (not one on its own field, which may
  // be the click that opened it). Not the save banner: it often appears in
  // response to that very click (the login button), and it has its own
  // "Şimdi değil" button.
  document.addEventListener('click', (e) => {
    if (host && hostIsPicker && !e.composedPath().includes(host) && e.target !== hostAnchor) closeUI();
  });

  // ------------------------------------------------- clickjacking guards
  //
  // A page can focus its own fields from script, restyle or cover anything in
  // its DOM, and time all that to the user's clicks — to get one click on an
  // invisible picker that fills a saved password into its fields. So the
  // picker only opens when the user really went to the field, both prompts
  // live in the top layer (above the page's own overlays, untouched by its
  // opacity or filters), and a click on them only counts when it was a real
  // click on something the user could actually see.
  let lastUserInput = { at: 0, target: null, key: '' };
  for (const type of ['pointerdown', 'keydown']) {
    window.addEventListener(
      type,
      (e) => {
        if (e.isTrusted) lastUserInput = { at: Date.now(), target: e.target, key: e.key || '' };
      },
      true,
    );
  }

  // Focus that follows the user's own click on the field (or its label) or
  // a Tab press — not a focus() call from the page.
  function focusedByUser(field) {
    if (Date.now() - lastUserInput.at > 1000) return false;
    if (lastUserInput.key === 'Tab') return true;
    const target = lastUserInput.target;
    return target === field || (target instanceof Node && [...(field.labels || [])].some((l) => l.contains(target)));
  }

  // Creates the shadow host, in the top layer when the browser has popovers.
  // Inside a page dialog or popover that holds the field, so it stays usable
  // (and above it) there.
  function mountHost(anchor, styles) {
    const el = document.createElement('div');
    for (const [name, value] of Object.entries({ all: 'initial', 'z-index': '2147483647', ...styles })) {
      el.style.setProperty(name, value, 'important');
    }
    const parent = anchor?.closest('dialog[open]') || document.body;
    parent.appendChild(el);
    if (typeof el.showPopover === 'function') {
      el.popover = 'manual';
      el.showPopover();
    }
    return el;
  }

  function inTopLayer(el) {
    try {
      return el.matches(':popover-open');
    } catch {
      return false;
    }
  }

  // Was [ev] a real click on Passlune's UI, as the user saw it?
  function clickOnShownUI(ev, shownAt) {
    if (!ev.isTrusted || !host || Date.now() - shownAt < 500) return false;
    if (document.elementFromPoint(ev.clientX, ev.clientY) !== host) return false;
    const box = host.getBoundingClientRect();
    if (box.width < 200 || box.height < 30) return false;
    // In the top layer only the host's own style applies to it; otherwise
    // every ancestor's opacity, filter or mask does too.
    const chain = [host];
    if (!inTopLayer(host)) for (let el = host.parentElement; el; el = el.parentElement) chain.push(el);
    let opacity = 1;
    for (const el of chain) {
      const s = getComputedStyle(el);
      opacity *= Number(s.opacity);
      const mask = s.maskImage || s.webkitMaskImage || 'none';
      if (s.visibility !== 'visible' || s.filter !== 'none' || s.clipPath !== 'none' || mask !== 'none' ||
        s.mixBlendMode !== 'normal') {
        return false;
      }
    }
    if (opacity < 0.95) return false;
    // A page dialog or popover opened after ours would be drawn over it.
    try {
      return ![...document.querySelectorAll(':popover-open, dialog:modal')].some((el) => el !== host && !el.contains(host));
    } catch {
      return true;
    }
  }

  function normHint(s) {
    return (s || '').toLowerCase().replace(/̇/g, '');
  }

  // Everything a field says about itself: attributes, its <label>, and an
  // aria-labelledby target.
  function fieldHint(el) {
    const label = [...(el.labels || [])].map((l) => l.textContent).join(' ');
    const labelledBy = (el.getAttribute('aria-labelledby') || '')
      .split(/\s+/)
      .map((id) => (id && document.getElementById(id)?.textContent) || '')
      .join(' ');
    return normHint(
      `${el.name} ${el.id} ${el.autocomplete} ${el.placeholder} ${el.getAttribute('aria-label') || ''} ${label} ${labelledBy}`,
    );
  }

  // Text right next to a field that isn't linked as a <label> — settings
  // pages often render "API Key" in a plain <div> above the input.
  function nearbyText(el) {
    let node = el.parentElement;
    for (let depth = 0; node && depth < 3; depth++, node = node.parentElement) {
      const text = (node.textContent || '').trim();
      if (text.length > 0 && text.length <= 120) return normHint(text);
      if (text.length > 120) break;
    }
    return '';
  }

  function isVisible(el) {
    return !!el && (el.offsetParent !== null || el.getClientRects().length > 0);
  }

  // A visible, typeable single-line field: the only kind that can hold a
  // login identifier (username, e-mail, phone, T.C. Kimlik No, ...).
  function isIdentifierCandidate(el) {
    // readOnly is deliberately allowed: some sites (e-Devlet among them)
    // mark the field readonly until it's focused, precisely to stop
    // browser autofill.
    if (el.tagName !== 'INPUT' || el.disabled) return false;
    const t = (el.type || 'text').toLowerCase();
    if (!['text', 'email', 'tel', 'number'].includes(t)) return false;
    return isVisible(el);
  }

  // Candidate whose name/id/placeholder/label says it's the identifier.
  // Includes Turkish hints — sites like e-Devlet call it "T.C. Kimlik No",
  // which the old English-only keywords never matched.
  function isUsernameField(el) {
    if (!isIdentifierCandidate(el)) return false;
    return (
      el.autocomplete === 'username' ||
      el.type === 'email' ||
      /user|e-?mail|login|kullan[ıi]c[ıi]|kimlik|tckn|\btc\b|t\.c\.|hesap|account|phone|telefon|gsm/.test(
        fieldHint(el),
      )
    );
  }

  function findUsernameFieldNear(pwField) {
    const form = pwField.closest('form') || document;
    const inputs = [...form.querySelectorAll('input')];
    const pwIndex = inputs.indexOf(pwField);
    // 1) A field that names itself as the identifier, preferring the one
    //    closest before the password field.
    for (let i = pwIndex - 1; i >= 0; i--) {
      if (isUsernameField(inputs[i])) return inputs[i];
    }
    const hinted = inputs.find((i) => i !== pwField && isUsernameField(i));
    if (hinted) return hinted;
    // 2) No hint anywhere: a login form is almost always "identifier +
    //    password", so take the nearest plain text field before it,
    //    whatever it happens to be called.
    for (let i = pwIndex - 1; i >= 0; i--) {
      if (isIdentifierCandidate(inputs[i])) return inputs[i];
    }
    return null;
  }

  // ------------------------------------------ password field vs. secret field

  // Sites mask lots of things that aren't account passwords: API keys and
  // tokens on settings pages, SMTP/webhook secrets, OTP and PIN boxes, card
  // CVCs. Those must neither raise "Şifre kaydedilsin mi?" nor get a login
  // filled into them.
  const SECRET_HINT =
    /api|token|secret|\bkey\b|[-_ ]key|key[-_ ]|anahtar|bearer|webhook|client.?id|private|otp|one.?time|2fa|totp|mfa|\bpin\b|cvv|cvc|\bcard|kart|iban|licen[cs]e|lisans|smtp/;
  // Looser surrounding text gets a narrower test: words like "kart" or
  // "card" appear around perfectly normal bank login forms.
  const NEARBY_SECRET_HINT = /\bapi\b|api key|api anahtar|token|secret|webhook|\bkey\b|smtp|bearer/;

  function looksLikeSecretField(pw) {
    const ac = normHint(pw.autocomplete);
    if (ac === 'one-time-code' || ac.startsWith('cc-')) return true;
    if (ac === 'current-password' || ac === 'new-password') return false;
    // Keys are commonly pasted as one long string; "apiKey"/"secretKey" in
    // camelCase becomes "apikey" once lowercased, so check that form too.
    const hint = fieldHint(pw);
    return SECRET_HINT.test(hint) || /apikey|secretkey|accesskey|privatekey/.test(hint) ||
      NEARBY_SECRET_HINT.test(nearbyText(pw));
  }

  const TEXTLIKE = 'input:not([type]), input[type="text"], input[type="email"], input[type="tel"], input[type="number"], input[type="url"], input[type="search"]';

  // The bit of page the password belongs to: its <form>, or for form-less
  // apps the nearest ancestor that also contains some other text field.
  function formScope(pw) {
    const form = pw.form || pw.closest('form');
    if (form) return form;
    let node = pw.parentElement;
    for (let depth = 0; node && depth < 6; depth++, node = node.parentElement) {
      if ([...node.querySelectorAll(TEXTLIKE)].some(isVisible)) return node;
    }
    return pw.parentElement || document.body;
  }

  // Settings and admin pages: on these a lone masked field is far more likely
  // to be a key than a login, unless the page says it's about passwords.
  const SETTINGS_PATH = /setting|ayar|admin|config|integration|entegrasyon|preference|tercih|dashboard|panel|\/api\b|developer|webhook/;

  const LOGIN_PATH = /login|log-in|signin|sign-in|signup|register|giri[şs]|auth|oturum|kay[ıi]t/;

  // A login, signup or change-password form — as opposed to a settings form
  // that happens to contain a masked field. Sign-up forms legitimately have a
  // handful of fields; a settings form usually has many, or free text.
  function looksLikeCredentialForm(pw) {
    const scope = formScope(pw);
    const visible = (sel) => [...scope.querySelectorAll(sel)].filter(isVisible);
    if (visible('textarea').length > 0) return false;
    const textFields = visible(TEXTLIKE).length + visible('select').length;
    const pwFields = visible('input[type="password"]').length;
    if (pwFields > 3 || textFields > 6) return false;
    const ac = normHint(pw.autocomplete);
    const passwordy = ac === 'current-password' || ac === 'new-password' ||
      /pass|pwd|şifre|sifre|parola/.test(fieldHint(pw));
    const path = normHint(location.pathname);
    if (SETTINGS_PATH.test(path) && !LOGIN_PATH.test(path) && !passwordy) {
      // e.g. /admin/ai/settings with "Model" + a masked key: only a field
      // that calls itself a password, next to a real username field, counts.
      return false;
    }
    return true;
  }

  function isLoginPasswordField(pw) {
    return !looksLikeSecretField(pw) && looksLikeCredentialForm(pw);
  }

  // ---------------------------------------------------- insecure page notice

  function isPrivateHost(h) {
    h = (h || '').toLowerCase();
    return (
      h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.local') ||
      h === '[::1]' || !h.includes('.') ||
      /^127\./.test(h) || /^10\./.test(h) || /^192\.168\./.test(h) ||
      /^169\.254\./.test(h) || /^172\.(1[6-9]|2\d|3[01])\./.test(h)
    );
  }
  const insecurePage = location.protocol === 'http:' && !isPrivateHost(location.hostname);
  const INSECURE_NOTE = insecurePage
    ? `<div class="warn">⚠ ${t('Bu sayfa şifrelenmemiş (http). Girdiğiniz şifre ağda okunabilir.', 'This page is not encrypted (http). What you type can be read on the network.')}</div>`
    : '';
  const WARN_CSS =
    '.warn{background:#3a2a10;color:#f5c26b;font-size:12px;padding:6px 10px;border-bottom:1px solid #5a4318}';
  // Passlune mark, same geometry as the app's (lib/theme.dart).
  const LOGO = '<svg class="logo" width="20" height="20" viewBox="0 0 100 100" aria-hidden="true"><defs><mask id="pl-cm"><rect width="100" height="100" fill="#fff"/><circle cx="64" cy="41" r="25" fill="#000"/><circle cx="32" cy="47" r="5" fill="#000"/><polygon points="29.5,49 34.5,49 36,61 28,61" fill="#000"/></mask></defs><circle cx="50" cy="50" r="44" fill="none" stroke="#e8b04b" stroke-opacity=".55" stroke-width="3"/><circle cx="47" cy="50" r="31" fill="#e8b04b" mask="url(#pl-cm)"/></svg>';
  const THEME_CSS =
    '.logo{flex-shrink:0;filter:drop-shadow(0 0 4px rgba(232,176,75,.4))}';

  // Fills a closed shadow root from a template (styles + markup) without
  // innerHTML. Dynamic values in the templates are escaped by escapeHtml.
  function fillShadow(root, html) {
    const doc = new DOMParser().parseFromString(html, 'text/html');
    const nodes = [...doc.head.childNodes, ...doc.body.childNodes];
    root.replaceChildren(...nodes.map((n) => document.importNode(n, true)));
  }

  function setValue(el, value) {
    const proto = el.tagName === 'INPUT' ? window.HTMLInputElement.prototype : null;
    const setter = proto && Object.getOwnPropertyDescriptor(proto, 'value')?.set;
    setter ? setter.call(el, value) : (el.value = value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // ----------------------------------------------------- autofill dropdown

  // Once the user closes the picker (×, Esc) or just starts typing into the
  // field, they're entering things by hand — stop popping it back up on
  // every focus for the rest of this page, or it keeps covering the very
  // fields they're trying to reach.
  let pickerDismissed = false;
  function dismissPicker() {
    pickerDismissed = true;
    closeUI();
  }
  document.addEventListener(
    'keydown',
    (e) => {
      if (e.key === 'Escape' && host) dismissPicker();
    },
    true,
  );

  async function showPicker(anchor, pwField, userField) {
    if (pickerDismissed) return;
    closeUI();
    const res = await send({ type: 'LIST' });
    if (!res.ok || res.entries.length === 0) return;
    // The lookup is async: don't pop up late over a field the user has
    // already left, or after they've started typing / closed it meanwhile.
    if (pickerDismissed || document.activeElement !== anchor) return;

    closeUI();
    host = mountHost(anchor, { position: 'fixed', 'font-family': 'sans-serif' });
    hostIsPicker = true;
    hostAnchor = anchor;
    const root = host.attachShadow({ mode: 'closed' });
    fillShadow(root, `
      <style>
        .box{background:#17150f;border:1px solid #3a3223;border-radius:14px;
          box-shadow:0 10px 32px rgba(0,0,0,.45),0 0 0 1px rgba(232,176,75,.08);min-width:250px;max-width:330px;
          overflow:hidden;font-size:13px;color:#eceef3;font-family:system-ui,-apple-system,"Segoe UI",sans-serif}
        .hdr{display:flex;align-items:center;justify-content:space-between;gap:8px;
          padding:9px 8px 9px 12px;font-weight:700;background:#0c0b09;border-bottom:1px solid #3a3223}
        .hdr span{display:flex;align-items:center;gap:8px}
        .x{all:unset;cursor:pointer;width:24px;height:24px;line-height:24px;text-align:center;
          border-radius:7px;font-size:16px;color:#9aa1b2}
        .x:hover{background:#201d16;color:#eceef3}
        .item{display:flex;flex-direction:column;padding:9px 12px;cursor:pointer;border-bottom:1px solid #26221a}
        .item:last-child{border-bottom:none}
        .item:hover{background:#201d16}
        .site{font-weight:700}
        .user{color:#9aa1b2;font-size:12px}
        ${WARN_CSS}
        ${THEME_CSS}
      </style>
      <div class="box">
        <div class="hdr"><span>${LOGO} Passlune — ${t('kayıtlı girişler', 'saved logins')}</span>
          <button class="x" id="k-close" title="${t('Kapat (Esc)', 'Close (Esc)')}" aria-label="${t('Kapat', 'Close')}">×</button></div>
        ${INSECURE_NOTE}
        ${res.entries
          .map(
            (e, i) =>
              `<div class="item" data-i="${i}"><span class="site">${escapeHtml(
                e.site,
              )}</span><span class="user">${escapeHtml(e.username)}</span></div>`,
          )
          .join('')}
      </div>`);
    positionNear(host, anchor);
    const pickerHost = host;
    const shownAt = Date.now();
    // Fixed to the viewport (the top layer), so it follows the field.
    const follow = () => positionNear(pickerHost, anchor);
    window.addEventListener('scroll', follow, true);
    window.addEventListener('resize', follow);
    hostCleanup = () => {
      window.removeEventListener('scroll', follow, true);
      window.removeEventListener('resize', follow);
    };
    const closeThisPicker = () => {
      if (host === pickerHost) closeUI();
    };
    // Clicking anywhere in the list must not blur the field, or the
    // focusout handler below would close the list before the click lands.
    root.querySelector('.box').addEventListener('mousedown', (e) => e.preventDefault());
    root.getElementById('k-close').addEventListener('mousedown', (e) => {
      e.preventDefault();
      dismissPicker();
    });
    // Leaving the field (Tab, a click on "İleri"/"Atla", another field)
    // closes the list, so it can never sit over the page's own buttons.
    anchor.addEventListener('focusout', closeThisPicker, { once: true });
    // Typing means manual entry — get out of the way.
    anchor.addEventListener(
      'input',
      () => {
        pickerDismissed = true;
        closeThisPicker();
      },
      { once: true },
    );
    root.querySelectorAll('.item').forEach((el) => {
      el.addEventListener('click', async (ev) => {
        if (host !== pickerHost || !clickOnShownUI(ev, shownAt)) return;
        const entry = res.entries[Number(el.dataset.i)];
        const rev = await send({ type: 'REVEAL', id: entry.id });
        if (!rev.ok) return closeUI();
        if (userField) setValue(userField, rev.username);
        if (pwField) setValue(pwField, rev.password);
        if (rev.username) rememberIdentifierValue(rev.username);
        closeUI();
      });
    });
  }

  // Prefer the right-hand side of the field so the list never covers the
  // fields below it (password, confirm password, ...); fall back to below
  // the field only when there isn't room on the right.
  // Viewport coordinates: the host is position:fixed.
  function positionNear(el, anchor) {
    const r = anchor.getBoundingClientRect();
    const width = el.getBoundingClientRect().width || 320;
    const right = r.right + 8 + width <= document.documentElement.clientWidth;
    el.style.setProperty('left', `${right ? r.right + 8 : r.left}px`, 'important');
    el.style.setProperty('top', `${right ? r.top : r.bottom + 4}px`, 'important');
  }

  function escapeHtml(s) {
    return String(s ?? '').replace(
      /[&<>"']/g,
      (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
    );
  }

  function attachPicker(pwField) {
    if (pwField.__kasaAttached) return;
    // Decided on first sight; a key field never becomes a login field.
    if (looksLikeSecretField(pwField)) {
      pwField.__kasaAttached = true;
      return;
    }
    pwField.__kasaAttached = true;
    const userField = findUsernameFieldNear(pwField);
    for (const field of [pwField, userField]) {
      if (field) openPickerOnUserFocus(field, () => looksLikeCredentialForm(pwField) && showPicker(field, pwField, userField));
    }
  }

  // Opens on focus the user caused, and on a click into a field that already
  // has focus (autofocus fires no focus event the user caused).
  function openPickerOnUserFocus(field, open) {
    field.addEventListener('focus', () => focusedByUser(field) && open());
    field.addEventListener('pointerdown', (e) => {
      if (e.isTrusted && document.activeElement === field && !(host && hostIsPicker)) open();
    });
  }

  // For multi-step logins (Google-style: email first, password on the next
  // page) there's no password field yet — still offer to fill the username
  // so the picker isn't silently unavailable on the first step.
  function attachUsernameOnlyPicker(userField) {
    if (userField.__kasaAttached) return;
    userField.__kasaAttached = true;
    openPickerOnUserFocus(userField, () => showPicker(userField, null, userField));
  }

  // Stricter than isUsernameField, for fields with no password next to them:
  // phone / account / "hesap" hints are everywhere in profile, address and
  // recovery-info forms (e.g. Google's after-login "add your address"
  // pages), so on their own they no longer pop the saved-logins list.
  function isLoginIdentifier(el) {
    if (!isIdentifierCandidate(el)) return false;
    return /username|user|login|identifier|kullan[ıi]c[ıi]|kimlik|tckn|\btc\b|t\.c\.|e-?mail|e-?posta/.test(
      fieldHint(el),
    );
  }

  function scan() {
    document.querySelectorAll('input[type="password"]').forEach(attachPicker);
    document.querySelectorAll('input').forEach((el) => {
      if (el.__kasaAttached || el.type === 'password' || !isLoginIdentifier(el)) return;
      const form = el.closest('form') || document;
      if (form.querySelector('input[type="password"]')) return;
      // A login step has one or two fields; a form with many is a profile /
      // address / signup form, not a place to offer saved logins.
      const fields = [...form.querySelectorAll('input')].filter(isIdentifierCandidate);
      if (fields.length <= 2) attachUsernameOnlyPicker(el);
    });
  }
  scan();
  new MutationObserver(scan).observe(document.documentElement, {
    childList: true,
    subtree: true,
  });

  // ----------------------------------------------------- save-password prompt

  // A successful login usually navigates away (or reloads) right after the
  // click, which would destroy the banner before it can be clicked. So the
  // candidate is handed to the background first — before anything else —
  // and picked back up on whichever page of this tab loads next, within a
  // short window (the background enforces the window and the site match).
  function stashPendingSave(username, password) {
    // Fire-and-forget, deliberately not awaited: awaiting here would let a
    // fast page navigation abort this function before the message is even
    // dispatched. sendMessage() posts immediately.
    send({ type: 'PENDING_STASH', username, password });
  }

  async function restorePendingSave() {
    const res = await send({ type: 'PENDING_TAKE' });
    const p = res.ok && res.pending;
    if (!p) return;
    // Not cleared on the first show: a login can bounce through a redirect
    // before landing, which would destroy the banner before it's clicked.
    // It's cleared once the user acts on it (see offerSaveBanner), after a
    // couple of page loads, or once the time window passes.
    await offerSaveIfNew(p.site, p.username, p.password);
  }

  async function offerSaveIfNew(site, username, password) {
    // Same user + same password for this site: nothing new to save. The
    // background compares, so stored passwords never come to the page.
    const check = await send({ type: 'SAVE_CHECK', username, password });
    if (check.ok && check.known) return;
    offerSaveBanner(site, username, password, check.ok && check.isUpdate);
  }

  // Only a password the user actually typed (or pasted) counts as a login
  // worth offering to save. Browser autofill — Edge/Chrome's own password
  // manager filling a hidden login box in a site header on every page —
  // and Kasa's own fill both change the value without a user edit, so they
  // no longer trigger "Şifre kaydedilsin mi?" on every navigation.
  //
  // The signal is the trusted InputEvent's inputType rather than keydown:
  // on-screen keyboards, IMEs and some paste paths never fire keydown, while
  // autofill reports either no inputType (Chromium) or
  // "insertReplacementText" (Firefox) and also matches :autofill.
  const typedPasswords = new WeakSet();
  const USER_EDIT = /^(insert(Text|CompositionText|FromPaste|FromDrop|LineBreak)|delete)/;
  function isAutofilled(el) {
    for (const sel of [':autofill', ':-webkit-autofill']) {
      try {
        if (el.matches(sel)) return true;
      } catch {
        /* selector unsupported in this browser */
      }
    }
    return false;
  }
  document.addEventListener(
    'input',
    (e) => {
      const el = e.target;
      if (!(el instanceof HTMLInputElement) || el.type !== 'password' || !e.isTrusted) return;
      if (USER_EDIT.test(e.inputType || '') && !isAutofilled(el)) typedPasswords.add(el);
    },
    true,
  );

  function userEnteredPassword(pw) {
    return !!pw && !!pw.value && typedPasswords.has(pw) && isVisible(pw) && isLoginPasswordField(pw);
  }

  // Multi-step logins (Google, Microsoft, ...) ask for the e-mail on one
  // step and the password on the next, where the e-mail field is gone or
  // hidden. Remember what was entered on the identifier step (typed or
  // filled from Kasa) so the save prompt on the password step isn't blank —
  // and so an already-saved login is recognised instead of offered again.
  // The background keeps it per tab and per site.
  let lastIdentifier = '';
  send({ type: 'ID_GET' }).then((res) => {
    if (res.ok && res.value && !lastIdentifier) lastIdentifier = res.value;
  });
  function rememberIdentifierValue(value) {
    value = (value || '').trim();
    if (!value) return;
    lastIdentifier = value;
    send({ type: 'ID_REMEMBER', value });
  }
  document.addEventListener(
    'change',
    (e) => {
      const el = e.target;
      if (el instanceof HTMLInputElement && isLoginIdentifier(el)) rememberIdentifierValue(el.value);
    },
    true,
  );

  // Picking a remembered account ("Choose an account" on Google and the
  // like) never types the e-mail: the chooser rows carry it in a data
  // attribute instead, so remember it on click.
  const ID_ATTRS = ['data-identifier', 'data-email', 'data-username'];
  document.addEventListener(
    'click',
    (e) => {
      const row = e.target instanceof Element ? e.target.closest(ID_ATTRS.map((a) => `[${a}]`).join(',')) : null;
      if (!row) return;
      const v = ID_ATTRS.map((a) => row.getAttribute(a)).find((x) => x && x.trim());
      if (v) rememberIdentifierValue(v);
    },
    true,
  );

  const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;

  // On the password step the account is often only shown as text ("x@gmail.com
  // ▾" above the box). Read it from a data attribute, or from the text of the
  // nearest enclosing blocks.
  function identifierShownNear(pwField) {
    for (const a of ID_ATTRS) {
      const el = document.querySelector(`[${a}]`);
      const v = el && el.getAttribute(a);
      if (v && v.trim()) return v.trim();
    }
    let node = pwField.parentElement;
    for (let depth = 0; node && depth < 10; depth++, node = node.parentElement) {
      const text = (node.innerText || '').slice(0, 4000);
      const m = text.match(EMAIL_RE);
      if (m) return m[0];
    }
    return '';
  }

  function usernameFor(pwField) {
    const field = findUsernameFieldNear(pwField);
    return (field && field.value.trim()) || lastIdentifier || identifierShownNear(pwField);
  }

  async function maybeOfferSave(pwField) {
    if (!userEnteredPassword(pwField)) return;
    const value = pwField.value;
    const username = usernameFor(pwField);
    stashPendingSave(username, value); // not awaited, see comment above
    await offerSaveIfNew(location.hostname, username, value);
  }

  // Belt-and-suspenders for very fast redirects: some sites navigate away
  // within milliseconds of the click, faster than a click-time message can
  // reliably land. So a password the user is typing is also stashed while
  // they type — by the time they click submit, the value from their last
  // keystroke (debounced a little) is almost always already stashed.
  let typingTimer = null;
  document.addEventListener(
    'input',
    (e) => {
      const el = e.target;
      if (!(el instanceof HTMLInputElement) || el.type !== 'password') return;
      if (!userEnteredPassword(el)) return;
      clearTimeout(typingTimer);
      typingTimer = setTimeout(() => stashPendingSave(usernameFor(el), el.value), 250);
    },
    true,
  );

  // Only the top frame shows the banner, so an embedded frame can't stack
  // a second one over the page.
  if (window.top === window) restorePendingSave();

  function offerSaveBanner(site, username, password, isUpdate) {
    if (!document.body) {
      return whenBodyReady(() => offerSaveBanner(site, username, password, isUpdate));
    }
    closeUI();
    host = mountHost(null, { position: 'fixed', top: '16px', right: '16px', 'font-family': 'sans-serif' });
    hostIsPicker = false;
    const bannerHost = host;
    const shownAt = Date.now();
    const root = host.attachShadow({ mode: 'closed' });
    fillShadow(root, `
      <style>
        .card{background:radial-gradient(120% 60% at 50% -10%,rgba(232,176,75,.16),transparent 70%),#17150f;
          border:1px solid #3a3223;border-radius:16px;
          box-shadow:0 12px 36px rgba(0,0,0,.5),0 0 0 1px rgba(232,176,75,.08);width:310px;padding:16px;
          font-size:13px;color:#eceef3;overflow:hidden;font-family:system-ui,-apple-system,"Segoe UI",sans-serif}
        .title{font-weight:800;font-size:14px;margin-bottom:8px;display:flex;align-items:center;gap:8px}
        label{display:block;font-size:11px;color:#9aa1b2;margin-top:9px}
        input{width:100%;box-sizing:border-box;padding:8px 10px;margin-top:4px;color:#eceef3;
          background:#201d16;border:1px solid #3a3223;border-radius:10px;font-size:13px;outline:none}
        input:focus{border-color:#e8b04b;box-shadow:0 0 0 3px rgba(232,176,75,.18)}
        .row{display:flex;gap:8px;margin-top:14px}
        button{flex:1;padding:9px;border-radius:10px;border:none;font-size:13px;cursor:pointer;font-family:inherit}
        button:hover{filter:brightness(1.12)}
        .save{background:#e8b04b;color:#111;font-weight:700;box-shadow:0 4px 16px rgba(232,176,75,.25)}
        .skip{background:#201d16;color:#eceef3;border:1px solid #3a3223}
        .err{color:#ff5a5f;font-size:12px;margin-top:8px;display:none}
        ${WARN_CSS}
        ${THEME_CSS}
        .warn{margin:-14px -14px 10px;padding:8px 14px}
      </style>
      <div class="card">
        ${INSECURE_NOTE}
        <div class="title">${LOGO} ${isUpdate ? t('Şifre güncellensin mi?', 'Update the password?') : t('Şifre kaydedilsin mi?', 'Save the password?')}</div>
        <label>Site</label><input id="k-site">
        <label>${t('Kullanıcı adı', 'Username')}</label><input id="k-user">
        <label>${t('Şifre', 'Password')}</label><input id="k-pass" type="password">
        <div class="err" id="k-err"></div>
        <div class="row">
          <button class="skip" id="k-skip">${t('Şimdi değil', 'Not now')}</button>
          <button class="save" id="k-save">${isUpdate ? t('Güncelle', 'Update') : t('Kaydet', 'Save')}</button>
        </div>
      </div>`);
    // Values are set as properties, never spliced into HTML.
    root.getElementById('k-site').value = site;
    root.getElementById('k-user').value = username;
    root.getElementById('k-pass').value = password;
    root.getElementById('k-skip').addEventListener('click', () => {
      send({ type: 'PENDING_CLEAR' });
      closeUI();
    });
    root.getElementById('k-save').addEventListener('click', async (ev) => {
      if (host !== bannerHost || !clickOnShownUI(ev, shownAt)) return;
      const saveBtn = root.getElementById('k-save');
      const label = saveBtn.textContent;
      const err = root.getElementById('k-err');
      saveBtn.disabled = true;
      saveBtn.textContent = t('Kaydediliyor…', 'Saving…');
      const res = await send({
        type: 'UPSERT',
        entry: {
          site: root.getElementById('k-site').value.trim(),
          username: root.getElementById('k-user').value.trim(),
          password: root.getElementById('k-pass').value,
        },
      });
      if (res && res.ok) {
        send({ type: 'PENDING_CLEAR' });
        if (!res.warning) return closeUI();
        // Saved, but only on this device for now: say so before closing.
        saveBtn.textContent = t('Kaydedildi', 'Saved');
        err.style.cssText = 'display:block;color:#f5c26b';
        err.textContent = res.warning;
        setTimeout(() => host === bannerHost && closeUI(), 5000);
        return;
      }
      saveBtn.disabled = false;
      saveBtn.textContent = label;
      err.style.display = 'block';
      err.textContent =
        res?.error === 'locked'
          ? t(
              'Passlune kilitli. Uzantı simgesine tıklayıp ana şifreyle kilidi açın, sonra tekrar Kaydet’e basın.',
              'Passlune is locked. Click the extension icon, unlock with the master password, then press Save again.',
            )
          : `${t('Kaydedilemedi', "Couldn't save")}: ${res?.error || t('bilinmeyen hata', 'unknown error')}`;
    });
  }

  let lastOfferAt = 0;
  document.addEventListener(
    'submit',
    (e) => {
      const form = e.target;
      if (!(form instanceof HTMLFormElement)) return;
      const pw = [...form.querySelectorAll('input[type="password"]')].find(userEnteredPassword);
      if (pw && Date.now() - lastOfferAt >= 1500) {
        lastOfferAt = Date.now();
        maybeOfferSave(pw);
      }
    },
    true,
  );

  // Many login forms never fire a native 'submit' event — the site's own JS
  // handles the click and does a fetch/XHR instead. Catch that too, but only
  // for a button that belongs with the password the user just typed: in the
  // same <form>, or (for form-less pages) one whose text says it's a login
  // button. Previously any button anywhere on the page (search, menus, ...)
  // counted, which is how unrelated clicks kept raising the prompt.
  const LOGIN_TEXT = /giri[şs]|log\s*[iı]n|sign\s*in|sign\s*up|kay[ıi]t ol|oturum a[çc]|devam|continue|next|ileri/;
  function buttonText(el) {
    return normHint((el.textContent || el.value || el.getAttribute('aria-label') || '').trim());
  }
  function isSubmitLike(el) {
    if (el.tagName === 'BUTTON') return el.type === 'submit' || !el.getAttribute('type');
    if (el.tagName === 'INPUT') return el.type === 'submit';
    return false;
  }
  document.addEventListener(
    'click',
    (e) => {
      const btn = e.target.closest?.('button, input[type="submit"], input[type="button"], a, [role="button"]');
      if (!btn || Date.now() - lastOfferAt < 1500) return;
      const pw = [...document.querySelectorAll('input[type="password"]')].find(userEnteredPassword);
      if (!pw) return;
      const pwForm = pw.form || pw.closest('form');
      const btnForm = btn.form || btn.closest('form');
      const belongs = pwForm
        ? btnForm === pwForm && (isSubmitLike(btn) || LOGIN_TEXT.test(buttonText(btn)))
        : LOGIN_TEXT.test(buttonText(btn));
      if (!belongs) return;
      lastOfferAt = Date.now();
      // Stashed immediately, synchronously with the click — a real login
      // click often navigates away within well under 250ms, so any delay
      // here risks losing the message before it's sent.
      maybeOfferSave(pw);
    },
    true,
  );
})();
