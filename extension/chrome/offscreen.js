// Chrome/Edge only. The background service worker has no DOM and so no
// clipboard; it opens this hidden document just long enough to overwrite a
// copied password with an empty string.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg?.target !== 'offscreen' || msg.type !== 'CLEAR_CLIPBOARD') return false;
  if (sender.id !== chrome.runtime.id) return false;
  const onCopy = (e) => {
    e.clipboardData.setData('text/plain', '');
    e.preventDefault();
  };
  document.addEventListener('copy', onCopy, true);
  try {
    document.execCommand('copy');
  } finally {
    document.removeEventListener('copy', onCopy, true);
  }
  sendResponse({ ok: true });
  return false;
});
