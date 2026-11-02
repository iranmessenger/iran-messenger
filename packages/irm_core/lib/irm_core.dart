/// Shared core of the IRAN Messenger clients: protocol state,
/// device crypto, the signed REST client and the messenger service.
library;

export 'src/api_client.dart';
export 'src/app_db.dart';
export 'src/backup.dart';
export 'src/device_crypto.dart';
export 'src/files.dart';
export 'src/media_transfer.dart';
export 'src/messenger.dart';
export 'src/models.dart';
export 'src/sql_signal_store.dart';
export 'src/platform_io.dart'
    if (dart.library.js_interop) 'src/platform_web.dart'
    show openAppDb, openFileStore;
