// Tiny key/value store in the extension origin's IndexedDB.
//
// Used for the Google refresh token instead of storage.local: content
// scripts can read storage.local, but they run with the *web page's*
// origin for IndexedDB, so they can never reach this database. Only
// extension pages (background, popup) can.
const DB_NAME = 'kasa';
const STORE = 'kv';

let dbPromise = null;
function openDb() {
  dbPromise ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => {
      dbPromise = null;
      reject(req.error);
    };
  });
  return dbPromise;
}

async function run(mode, fn) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode);
    const req = fn(tx.objectStore(STORE));
    tx.oncomplete = () => resolve(req?.result);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

export const kvGet = (key) => run('readonly', (s) => s.get(key));
export const kvSet = (key, value) => run('readwrite', (s) => s.put(value, key));
export const kvDelete = (key) => run('readwrite', (s) => s.delete(key));
