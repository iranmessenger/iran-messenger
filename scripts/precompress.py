"""Writes .br and .gz copies of the web app's large binary files.

Hosts compress text on the fly but usually send WebAssembly and fonts as
they are. The .htaccess of the web app serves these ready-made copies
instead, which cuts the first download roughly in half.

    python scripts/precompress.py plugin/iran-messenger/app
"""
import gzip
import os
import sys

import brotli

root = sys.argv[1]
before = after = 0
for folder, _, names in os.walk(root):
    for name in names:
        if not name.endswith(('.wasm', '.ttf', '.otf')):
            continue
        path = os.path.join(folder, name)
        data = open(path, 'rb').read()
        small = brotli.compress(data, quality=11)
        open(path + '.br', 'wb').write(small)
        with open(path + '.gz', 'wb') as raw:
            # mtime=0 keeps the output identical from build to build.
            with gzip.GzipFile(fileobj=raw, mode='wb', compresslevel=9, mtime=0) as z:
                z.write(data)
        before += len(data)
        after += len(small)
print('precompressed: %.1f MB -> %.1f MB (brotli)' % (before / 1e6, after / 1e6))
