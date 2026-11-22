// Copies the files the Chrome/Edge and Firefox builds share from chrome/ to
// firefox/, so the two can't drift apart. Browser-specific files
// (manifest.json, lib/drive.js, lib/config.js, offscreen.*) are left alone.
//
//   node tools/sync-shared.js          copy
//   node tools/sync-shared.js --check  only report differences (exit 1 if any)
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const from = path.join(root, 'chrome');
const to = path.join(root, 'firefox');

const SHARED = [
  'background.js',
  'content.js',
  'content.css',
  'popup.js',
  'popup.html',
  'popup.css',
  'lib/crypto.js',
  'lib/domain.js',
  'lib/psl-data.js',
  'lib/kv.js',
  'lib/argon2.umd.min.js',
  '_locales/en/messages.json',
  '_locales/tr/messages.json',
  ...fs.readdirSync(path.join(from, 'icons')).map((f) => `icons/${f}`),
];

const check = process.argv.includes('--check');
let differing = 0;
for (const rel of SHARED) {
  const src = fs.readFileSync(path.join(from, rel));
  const dst = path.join(to, rel);
  const same = fs.existsSync(dst) && fs.readFileSync(dst).equals(src);
  if (same) continue;
  differing++;
  if (check) {
    console.log(`farklı: ${rel}`);
  } else {
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.writeFileSync(dst, src);
    console.log(`kopyalandı: ${rel}`);
  }
}
if (!differing) console.log('Ortak dosyalar aynı.');
if (check && differing) process.exit(1);
