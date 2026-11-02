import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'api_client.dart';
import 'app_db.dart';
import 'device_crypto.dart';
import 'files.dart';
import 'media_transfer.dart';
import 'models.dart';
import 'sql_signal_store.dart';

part 'messenger_extras.dart';
part 'messenger_fun.dart';
part 'messenger_groups.dart';
part 'messenger_reads.dart';
part 'messenger_send.dart';
part 'messenger_social.dart';
part 'messenger_sync.dart';
part 'messenger_wipe.dart';

/// Everything a client does, independent of any UI toolkit: registration,
/// directory, direct and group messages, attachments, sync and retry.
class Messenger {
  Messenger(this.db, this.files, {http.Client? httpClient, this.wafLog})
    : _http = httpClient,
      store = SqlSignalStore(db) {
    crypto = DeviceCrypto(store);
    media = MediaTransfer(this);
    final site = db.kvString('site');
    if (site != null) _openApi(site);
  }

  final AppDb db;

  /// Private storage for decrypted attachments.
  final FileStore files;
  final WafSink? wafLog;
  final http.Client? _http;
  final SqlSignalStore store;
  late final DeviceCrypto crypto;
  late final MediaTransfer media;
  ApiClient? _api;

  final _changes = StreamController<void>.broadcast();
  final _incoming = StreamController<ChatMessage>.broadcast();
  static final _rng = Random.secure();
  static final _ed = Ed25519();
  Future<bool>? _running;

  /// Set by the bot program: everything received except group membership
  /// is dropped unread. Members' apps send bots nothing else anyway.
  bool botMode = false;

  /// The round that follows the running one, shared by everyone who asked
  /// for a sync while it ran.
  Future<bool>? _nextRound;
  bool _sendingWaiting = false;
  bool _staleRetry = false;

  // Typing indicators are never stored: chat -> last send time, and
  // chat -> (who, visible until).
  final _typingSent = <String, int>{};
  final _typingSeen = <String, (int, int)>{};

  /// What this client understands beyond plain messages, sent along with
  /// everything it writes. 2: read receipts, delete for everyone, profile
  /// pictures. 3: deleting whole chats and leaving groups. 4: votes in
  /// polls. Older apps would show those as empty messages, so they are
  /// only sent to people whose app has announced the level they need.
  static const capability = 4;

  bool _capable(int identity, [int level = 2]) =>
      (db.kvInt('cap:$identity') ?? 1) >= level;

  /// Asks the server what the apps of [ids] understand, for those not yet
  /// known to be current. Each person is asked about at most every ten
  /// minutes; servers too old to know simply do not answer.
  Future<void> _learnCapabilities(Iterable<int> ids, [int level = 2]) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ask = [
      for (final id in {...ids})
        if (id != myIdentity &&
            !_capable(id, level) &&
            now - (db.kvInt('capchk:$id') ?? 0) > 600000)
          id,
    ];
    if (ask.isEmpty) return;
    try {
      await _loadAuthKey();
      final res =
          await api.post('/caps', {
                'mine': capability,
                'ids': ask.take(60).toList(),
              })
              as Map;
      final caps = res['caps'];
      for (final id in ask) {
        db.kvPutInt('capchk:$id', now);
        final c = caps is Map ? caps['$id'] : null;
        if (c is int && c > (db.kvInt('cap:$id') ?? 1)) {
          db.kvPutInt('cap:$id', c);
        }
      }
    } catch (_) {
      // Offline or an older server: fall back to what messages told us.
    }
  }

  /// People whose app announced itself during the current sync round.
  final _newlyCapable = <int>{};

  /// Identifies this instance when two isolates share one database.
  final String _instance = newId();

  /// Fires whenever stored data changed and views should reload.
  Stream<void> get changes => _changes.stream;

  /// Fires once per newly received, visible message.
  Stream<ChatMessage> get incoming => _incoming.stream;

  bool get isRegistered => db.kvInt('device_id') != null;
  int get myIdentity => db.kvInt('identity_id')!;
  String get myName => db.kvString('display_name') ?? '';
  String? get myUsername => db.kvString('username');
  String? get site => db.kvString('site');
  ApiClient get api => _api!;

  void notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static String newId() {
    String h(int n) =>
        List.generate(n, (_) => _rng.nextInt(16).toRadixString(16)).join();
    return '${h(8)}-${h(4)}-${h(4)}-${h(4)}-${h(12)}';
  }

  void _openApi(String site) {
    _api = ApiClient(site, httpClient: _http, wafLog: wafLog)
      ..deviceId = db.kvInt('device_id');
    _applyTrust(_api!);
  }

  Future<void> _loadAuthKey() async {
    api.authKey ??= await _ed.newKeyPairFromSeed(
      db.kvBytes('auth_seed')!.toList(),
    );
  }

  // ------------------------------------------------------------------
  // Registration
  // ------------------------------------------------------------------

  /// Creates an account. With a valid [inviteCode] it is active at once;
  /// without one it stays pending until the administrator approves it.
  Future<void> register({
    required String site,
    required String username,
    required String password,
    String inviteCode = '',
  }) => _enroll(site, '/auth/register', {
    'username': username.trim().toLowerCase().replaceFirst('@', ''),
    'password': password,
    if (inviteCode.trim().isNotEmpty) 'invite_code': inviteCode.trim(),
  });

  /// Signs in on a fresh installation. This device replaces the previous
  /// one: older messages cannot be recovered because their keys lived only
  /// on the old device.
  Future<void> login({
    required String site,
    required String username,
    required String password,
  }) => _enroll(site, '/auth/login', {
    'username': username.trim().toLowerCase().replaceFirst('@', ''),
    'password': password,
  });

  /// Keys are generated and stored before the network call, so a failed
  /// attempt can be retried without losing them.
  Future<void> _enroll(
    String site,
    String path,
    Map<String, dynamic> body,
  ) async {
    site = site.trim().replaceAll(RegExp(r'/+$'), '');
    if (!site.startsWith('http')) site = 'https://$site';

    final preKeyIds = await db.tx(() async {
      if (db.kvBytes('auth_seed') == null) {
        db.kvPutBytes(
          'auth_seed',
          List<int>.generate(32, (_) => _rng.nextInt(256)),
        );
      }
      final fresh = await crypto.provision();
      if (fresh.isNotEmpty) return fresh;
      return [
        for (final r in db.raw.select('SELECT id FROM prekeys ORDER BY id'))
          r['id'] as int,
      ];
    });

    final key = await _ed.newKeyPairFromSeed(db.kvBytes('auth_seed')!.toList());
    final device = await crypto.publicBundle(preKeyIds);
    device['auth_key'] = await ApiClient.publicKeyB64(key);

    final client = ApiClient(site, httpClient: _http, wafLog: wafLog);
    // A key built into the app lets even the very first request be
    // checked, and so be sent through a relay.
    if (builtInServerKey.isNotEmpty) {
      client.serverKey = base64Decode(builtInServerKey);
      client.relays = _storedRelays();
    }
    final res =
        await client.post(path, {...body, 'device': device}, signed: false)
            as Map;
    final offered = '${res['server_key'] ?? ''}';
    if (builtInServerKey.isNotEmpty && offered != builtInServerKey) {
      throw UntrustedResponse('enrolment');
    }

    await db.tx(() async {
      db.kvPutString('site', site);
      db.kvPutInt('device_id', res['device_id'] as int);
      db.kvPutInt('identity_id', res['identity_id'] as int);
      db.kvPutString('display_name', '${res['display_name']}');
      db.kvPutString('username', '${res['username']}');
      db.kvPutString('status', '${res['status']}');
      if (offered.isNotEmpty) db.kvPutString('server_key', offered);
    });
    _openApi(site);
    api.authKey = key;
    notify();
  }

  /// Server key compiled into the app (`--dart-define=SERVER_KEY=...`).
  static const builtInServerKey = String.fromEnvironment('SERVER_KEY');

  List<Relay> _storedRelays() {
    final raw = db.kvString('relays');
    if (raw == null) return const [];
    return [
      for (final r in jsonDecode(raw) as List)
        Relay('${r['url']}', '${r['key']}'),
    ];
  }

  void _applyTrust(ApiClient client) {
    final key =
        db.kvString('server_key') ??
        (builtInServerKey.isEmpty ? null : builtInServerKey);
    client.serverKey = key == null ? null : base64Decode(key);
    client.relays = _storedRelays();
  }

  /// "direct" or the relay host the last request went through.
  String get routeLabel => _api?.routeLabel ?? 'direct';

  /// Fetches the pinned server key (once) and the private relay list.
  Future<void> refreshConfig() async {
    await _loadAuthKey();
    final c = await api.get('/config') as Map;
    // Trust on first use for installs that predate signed answers; after
    // that the key never changes silently.
    if (db.kvString('server_key') == null && c['server_key'] is String) {
      db.kvPutString('server_key', c['server_key'] as String);
    }
    if (c['relays'] is List) db.kvPutString('relays', jsonEncode(c['relays']));
    if (c['contact_salt'] is String) {
      db.kvPutString('contact_salt', c['contact_salt'] as String);
    }
    if (c['vapid_key'] is String) {
      db.kvPutString('vapid_key', c['vapid_key'] as String);
    }
    if (c['bots'] is List) db.kvPutString('bots', jsonEncode(c['bots']));
    _applyTrust(api);
    // Let others know what this app understands.
    try {
      await api.post('/caps', {'mine': capability, 'ids': <int>[]});
    } catch (_) {}
  }

  /// True while the administrator has not approved this account yet.
  bool get isPending => db.kvString('status') == 'pending';

  void dispose() {
    _changes.close();
    _incoming.close();
    _api?.close();
  }
}
