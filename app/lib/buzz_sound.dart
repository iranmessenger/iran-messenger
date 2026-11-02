import 'package:audioplayers/audioplayers.dart';
import 'package:irm_core/irm_core.dart';

import 'platform/host.dart';

/// The sound an incoming BUZZ makes, chosen in settings. Each one is also
/// an Android raw resource, played by its own notification channel while
/// the app is closed (see background_io.dart).
const buzzSounds = {
  'doorbell': 'زنگ در (دینگ‌دانگ)',
  'knock': 'تق‌تق به شیشه',
  'classic': 'وزوز قدیمی',
  'none': 'بی‌صدا، فقط لرزش',
};

const _key = 'buzz_sound';

String buzzSoundOf(Messenger m) {
  final s = m.db.kvString(_key);
  return buzzSounds.containsKey(s) ? s! : 'doorbell';
}

void setBuzzSound(Messenger m, String sound) {
  m.db.kvPutString(_key, sound);
  m.notify();
}

AudioPlayer? _player;

/// Plays [sound] once, on the notification volume so a silenced phone
/// stays silent.
Future<void> playBuzzSound(String sound) async {
  if (sound == 'none') return;
  try {
    final p = _player ??= AudioPlayer()
      ..setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            usageType: AndroidUsageType.notificationEvent,
            contentType: AndroidContentType.sonification,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
          iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
        ),
      );
    await p.stop();
    await p.play(AssetSource('sounds/buzz_$sound.wav'));
  } catch (_) {
    // A browser may refuse sound before the page was touched.
  }
}

/// An incoming BUZZ while the app is on screen: vibration and sound.
Future<void> buzzAlert(Messenger m) async {
  await Future.wait([deviceBuzz(), playBuzzSound(buzzSoundOf(m))]);
}
