#!/usr/bin/env bash
# Builds the web app (for iPhone and any browser) into the plugin folder,
# from where WordPress serves it at /wp-content/plugins/iran-messenger/app/.
#
#   bash scripts/build-web.sh
set -euo pipefail
cd "$(dirname "$0")/../app"

MSYS_NO_PATHCONV=1 flutter build web --release \
  --base-href /wp-content/plugins/iran-messenger/app/ \
  --no-web-resources-cdn --no-wasm-dry-run

out=../plugin/iran-messenger/app
rm -rf "$out"
cp -r build/web "$out"
# Not used by this build: Flutter's own service worker and the WebAssembly
# renderers (the app is compiled to JavaScript and draws with CanvasKit).
rm -f "$out/flutter_service_worker.js" "$out/.last_build_id"
rm -rf "$out"/canvaskit/skwasm* "$out"/canvaskit/wimp* "$out"/canvaskit/experimental_webparagraph
find "$out" -name "*.symbols" -delete
python ../scripts/precompress.py "$out"
du -sh "$out"
