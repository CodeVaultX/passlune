// Site matching: decides which saved logins belong to which page.
//
// Loaded as a plain script (it sets globalThis.KasaDomain) so the background
// service worker / page and the popup can both `import` it for its side
// effect. Needs lib/psl-data.js to have run first.
//
// Rules:
//  * IP addresses, `localhost` and other single-label hosts match only the
//    exact same host — and the same port, when both sides name one. (The
//    old "last two labels" logic matched 192.168.0.1 with 10.0.0.1, since
//    both end in "0.1".)
//  * Everything else is compared by its registrable domain from the Public
//    Suffix List: accounts.google.com ~ mail.google.com (google.com), but
//    garanti.com.tr ≁ kotu-site.com.tr (com.tr is a public suffix) and
//    alice.github.io ≁ bob.github.io.
//  * A short, hand-maintained list of domain families lets one provider's
//    sign-in span several registrable domains (Microsoft, Google, ...).
(() => {
  const RULES = new Set((globalThis.KASA_PSL || '').split('\n').filter(Boolean));

  const DOMAIN_FAMILIES = [
    [
      'microsoft.com',
      'microsoftonline.com',
      'live.com',
      'outlook.com',
      'office.com',
      'office365.com',
      'msn.com',
      'hotmail.com',
      'xbox.com',
    ],
    ['google.com', 'gmail.com', 'youtube.com'],
    ['apple.com', 'icloud.com'],
    ['amazon.com', 'amazon.co.uk', 'amazon.de', 'amazon.com.tr', 'amazon.fr'],
    ['yahoo.com', 'yahoo.com.tr'],
  ];
  const FAMILY_OF = new Map(DOMAIN_FAMILIES.flatMap((group, i) => group.map((d) => [d, i])));

  function sameFamily(a, b) {
    if (a === b) return true;
    const fa = FAMILY_OF.get(a);
    return fa !== undefined && fa === FAMILY_OF.get(b);
  }

  // Accepts "https://x.com/path", "x.com", "192.168.0.1", "127.0.0.1:3002".
  function parse(value) {
    let s = String(value || '').trim();
    if (!s) return null;
    if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) s = `https://${s}`;
    try {
      const u = new URL(s);
      if (!u.hostname) return null;
      return { host: u.hostname.toLowerCase().replace(/\.$/, ''), port: u.port };
    } catch {
      return null;
    }
  }

  function isExactOnlyHost(host) {
    return (
      /^\d{1,3}(\.\d{1,3}){3}$/.test(host) || // IPv4
      host.startsWith('[') || // IPv6 (URL keeps the brackets)
      !host.includes('.') || // localhost, intranet names
      host.endsWith('.localhost')
    );
  }

  // Registrable domain ("eTLD+1") per the Public Suffix List algorithm, or
  // null when the host is itself a public suffix (e.g. "com.tr").
  function registrableDomain(host) {
    const labels = host.split('.');
    if (labels.some((l) => !l)) return null;
    let suffixLen = 1; // the implicit "*" rule
    for (let i = 0; i < labels.length; i++) {
      const candidate = labels.slice(i).join('.');
      if (RULES.has(`!${candidate}`)) {
        suffixLen = labels.length - i - 1;
        break;
      }
      if (RULES.has(candidate)) {
        suffixLen = labels.length - i;
        break;
      }
      if (i + 1 < labels.length && RULES.has(`*.${labels.slice(i + 1).join('.')}`)) {
        suffixLen = labels.length - i;
        break;
      }
    }
    if (suffixLen >= labels.length) return null;
    return labels.slice(labels.length - suffixLen - 1).join('.');
  }

  // Does a saved entry's site belong to this page (URL or host)?
  function matches(entrySite, page) {
    const a = parse(entrySite);
    const b = parse(page);
    if (!a || !b) return false;
    if (isExactOnlyHost(a.host) || isExactOnlyHost(b.host)) {
      if (a.host !== b.host) return false;
      return !a.port || !b.port || a.port === b.port;
    }
    const ra = registrableDomain(a.host);
    const rb = registrableDomain(b.host);
    if (!ra || !rb) return a.host === b.host;
    return sameFamily(ra, rb);
  }

  // Hosts where plain http is expected and not a network-sniffing risk.
  function isPrivateHost(value) {
    const p = parse(value);
    if (!p) return false;
    const h = p.host;
    if (h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) return true;
    if (h === '[::1]') return true;
    const m = /^(\d+)\.(\d+)\.\d+\.\d+$/.exec(h);
    if (!m) return !h.includes('.');
    const [a, b] = [Number(m[1]), Number(m[2])];
    return (
      a === 127 ||
      a === 10 ||
      (a === 192 && b === 168) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 169 && b === 254)
    );
  }

  function hostOf(value) {
    return parse(value)?.host || '';
  }

  globalThis.KasaDomain = { matches, registrableDomain, isPrivateHost, hostOf, parse };
})();
