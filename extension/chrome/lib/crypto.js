// AES-256-GCM + Argon2id vault crypto, wire-compatible with the Kasa
// desktop/mobile app's `vault.kasa` format:
//   { v:1, kdf:'argon2id', salt, nonce, ct, mac }  (all base64)
// Argon2id params must match the app exactly: memory=19456 KiB,
// iterations=2, parallelism=1, hashLength=32.
//
// Everything after unlock works from the derived key bytes; the master
// password itself is only needed to derive them.
import './argon2.umd.min.js';

const ARGON2 = { memorySize: 19456, iterations: 2, parallelism: 1, hashLength: 32 };

export function randomBytes(n) {
  return crypto.getRandomValues(new Uint8Array(n));
}

function b64e(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function b64d(str) {
  const s = atob(str);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

export class WrongPasswordError extends Error {}
export class CorruptVaultError extends Error {}

/** Raw 32-byte AES key derived from the master password. */
export async function deriveKeyRaw(password, salt) {
  return self.hashwasm.argon2id({ password, salt, ...ARGON2, outputType: 'binary' });
}

function importKey(keyRaw) {
  return crypto.subtle.importKey('raw', keyRaw, { name: 'AES-GCM' }, false, [
    'encrypt',
    'decrypt',
  ]);
}

export function parseBlob(bytes) {
  let j;
  try {
    j = JSON.parse(new TextDecoder().decode(bytes));
    if (j.v !== 1) throw 0;
  } catch {
    throw new CorruptVaultError();
  }
  return {
    salt: b64d(j.salt),
    nonce: b64d(j.nonce),
    ct: b64d(j.ct),
    mac: b64d(j.mac),
  };
}

export async function decryptWithKeyRaw(blob, keyRaw) {
  const key = await importKey(keyRaw);
  const combined = new Uint8Array(blob.ct.length + blob.mac.length);
  combined.set(blob.ct, 0);
  combined.set(blob.mac, blob.ct.length);
  let plain;
  try {
    plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: blob.nonce, additionalData: blob.salt },
      key,
      combined,
    );
  } catch {
    throw new WrongPasswordError();
  }
  try {
    return JSON.parse(new TextDecoder().decode(plain));
  } catch {
    throw new CorruptVaultError();
  }
}

export async function encryptWithKeyRaw(entries, keyRaw, salt) {
  const key = await importKey(keyRaw);
  const nonce = randomBytes(12);
  const plain = new TextEncoder().encode(JSON.stringify(entries));
  const combined = new Uint8Array(
    await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: salt }, key, plain),
  );
  const ct = combined.slice(0, combined.length - 16);
  const mac = combined.slice(combined.length - 16);
  return new TextEncoder().encode(
    JSON.stringify({
      v: 1,
      kdf: 'argon2id',
      salt: b64e(salt),
      nonce: b64e(nonce),
      ct: b64e(ct),
      mac: b64e(mac),
    }),
  );
}

export function newId() {
  return [...randomBytes(16)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Uniform integer in [0, n) — rejection sampling, no modulo bias. */
export function randomInt(n) {
  const limit = Math.floor(0x100000000 / n) * n;
  const buf = new Uint32Array(1);
  let x;
  do {
    crypto.getRandomValues(buf);
    x = buf[0];
  } while (x >= limit);
  return x % n;
}
