import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app_router.dart';
import 'app_state.dart';
import 'firebase_options.dart';
import 'flutter_conversion.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: const Color(0xFF140F0C),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Egg Sorting could not open this screen.\n${details.exceptionAsString()}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFE4A11B), fontSize: 16),
          ),
        ),
      ),
    );
  };
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {}
  final AppState appState = AppState();
  runApp(EggSystemBootstrap(appState: appState));
}

class EggSystemBootstrap extends StatefulWidget {
  const EggSystemBootstrap({super.key, required this.appState});

  final AppState appState;

  @override
  State<EggSystemBootstrap> createState() => _EggSystemBootstrapState();
}

class _EggSystemBootstrapState extends State<EggSystemBootstrap> {
  @override
  void initState() {
    super.initState();
    widget.appState.onUnauthenticated = () {
      final NavigatorState? nav = AppRouter.navigatorKey.currentState;
      if (nav == null) {
        return;
      }
      nav.pushNamedAndRemoveUntil(
        AppPaths.auth,
        (Route<dynamic> route) => false,
      );
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_afterFirstFrame());
    });
  }

  Future<void> _afterFirstFrame() async {
    try {
      await widget.appState.restoreLocalSession();
    } catch (_) {}
    if (!mounted) {
      return;
    }
    if (widget.appState.isAuthenticated) {
      AppRouter.navigatorKey.currentState?.pushNamedAndRemoveUntil(
        AppPaths.dashboard,
        (Route<dynamic> route) => false,
      );
    }
    try {
      await widget.appState.startBackgroundServices();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Egg Sorting',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE4A11B),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF140F0C),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
      ),
      navigatorKey: AppRouter.navigatorKey,
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData media = MediaQuery.of(context);
        final double scale = media.textScaler.scale(1.0).clamp(0.85, 1.15);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(scale)),
          child: child ?? AuthScreen(appState: widget.appState),
        );
      },
      initialRoute: AppPaths.auth,
      onGenerateRoute: (RouteSettings settings) =>
          AppRouter.onGenerateRoute(settings, widget.appState),
      onUnknownRoute: (RouteSettings settings) =>
          AppRouter.onGenerateRoute(settings, widget.appState),
    );
  }
}
