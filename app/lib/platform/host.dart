/// Everything that differs between a phone or desktop and a browser.
library;

export 'host_io.dart' if (dart.library.js_interop) 'host_web.dart';
