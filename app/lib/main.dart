import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import 'app_state.dart';
import 'background.dart';
import 'platform/host.dart';
import 'screens/home_screen.dart';
import 'screens/share_screen.dart';
import 'screens/auth_screen.dart';
import 'theme.dart';
import 'widgets/web_notices.dart';

/// Code, artwork and the font taken from other projects, next to the
/// pub.dev package licences Flutter registers by itself.
void _registerLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'flutter_UI_Kit',
      'fluttertemplates.dev',
      'flutter_animated_icons',
    ], await rootBundle.loadString('THIRD_PARTY_NOTICES.md'));
    yield LicenseEntryWithLineBreaks(const [
      'Vazirmatn',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
}

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  _registerLicenses();
  // The phone's own splash (navy with the logo) stays up while the
  // encrypted database opens, so there is no blank frame in between.
  if (!isWebApp) FlutterNativeSplash.preserve(widgetsBinding: binding);
  Object? startupError;
  AppState? state;
  try {
    BackgroundDelivery.init();
    state = await AppState.open();
  } catch (e) {
    startupError = e;
  }
  runApp(IrmApp(state: state, startupError: startupError));
  if (!isWebApp) FlutterNativeSplash.remove();
  // Needs a visible activity for the permission prompts.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    state?.applyBackground();
    if (state != null) ShareIntake.init(IrmApp.navigator, state);
  });
}

class IrmApp extends StatelessWidget {
  const IrmApp({
    super.key,
    this.state,
    this.startupError,
  });

  /// Lets code outside the widget tree (incoming shares) open screens.
  static final navigator = GlobalKey<NavigatorState>();

  final AppState? state;
  final Object? startupError;

  Widget _home() => state == null
      ? Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'پایگاه داده محلی باز نشد.\n$startupError',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        )
      : ListenableBuilder(
          listenable: state!,
          builder: (_, _) => !state!.messenger.isRegistered
              ? InstallGate(child: AuthScreen(state: state!))
              : state!.messenger.isPending
              ? PendingScreen(state: state!)
              : HomeScreen(state: state!),
        );

  ThemeMode get _mode => switch (state?.messenger.db.kvString('theme')) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  @override
  Widget build(BuildContext context) {
    final s = state;
    return s == null
        ? _app()
        : ListenableBuilder(listenable: s, builder: (_, _) => _app());
  }

  Widget _app() {
    return MaterialApp(
      themeMode: _mode,
      title: 'IRAN Messenger',
      navigatorKey: navigator,
      debugShowCheckedModeBanner: false,
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: Brand.theme(Brightness.light),
      darkTheme: Brand.theme(Brightness.dark),
      builder: (_, child) => WebFrame(child: child!),
      home: _home(),
    );
  }
}
