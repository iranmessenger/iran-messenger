// Service worker of the IRAN Messenger web app.
//
// Its only job is the new-message alert. The server sends a wake-up with
// no message content (it has none to send: messages are end-to-end
// encrypted); the text shown here is fixed.
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (event) {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', function (event) {
  event.waitUntil((async function () {
    const windows = await self.clients.matchAll(
        { type: 'window', includeUncontrolled: true });
    const watching = windows.some(function (w) {
      return w.visibilityState === 'visible';
    });
    // Browsers require an alert for every push, so one is always shown;
    // if the app is already on screen it is taken down again at once.
    await self.registration.showNotification('IRAN Messenger', {
      body: 'پیام تازه دارید',
      tag: 'irm-new-message',
      renotify: !watching,
      silent: watching,
      icon: 'icons/Icon-192.png',
      badge: 'icons/badge.png',
      dir: 'rtl',
      lang: 'fa',
    });
    if (watching) {
      const shown = await self.registration.getNotifications(
          { tag: 'irm-new-message' });
      shown.forEach(function (n) { n.close(); });
    }
  })());
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  event.waitUntil((async function () {
    const windows = await self.clients.matchAll(
        { type: 'window', includeUncontrolled: true });
    for (const w of windows) {
      if ('focus' in w) return w.focus();
    }
    return self.clients.openWindow(self.registration.scope);
  })());
});
