{{flutter_js}}
{{flutter_build_config}}

// No Flutter service worker: the app's own (sw.js) handles alerts, and two
// workers cannot share one folder.
// Fallback fonts (emoji, symbols) come from this site, never from a
// third party.
_flutter.loader.load({
  config: { fontFallbackBaseUrl: 'fallback/' },
});
