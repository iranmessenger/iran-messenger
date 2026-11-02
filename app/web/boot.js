// Removes the loading screen once Flutter has drawn its first frame, and
// registers the service worker that shows new-message alerts.
// The app needs a secure page: without https the browser refuses to store
// keys. Anyone who typed the address without it is sent to the https one.
if (location.protocol === 'http:' &&
    !/^(localhost|127\.0\.0\.1|\[::1\])$/.test(location.hostname)) {
  location.replace('https://' + location.host + location.pathname + location.search);
}

window.addEventListener('flutter-first-frame', function () {
  var boot = document.getElementById('boot');
  if (boot) boot.remove();
});
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('sw.js').catch(function () {});
}
setTimeout(function () {
  var text = document.getElementById('boot-text');
  if (text) text.textContent = 'بار اول کمی طول می‌کشد؛ دفعه‌های بعد سریع‌تر است…';
}, 12000);
