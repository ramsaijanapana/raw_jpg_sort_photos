import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialise window_manager on desktop (but not inside flutter test).
  final isDesktop = !kIsWeb &&
      (Platform.isLinux || Platform.isMacOS || Platform.isWindows);
  final isTest = Platform.environment['FLUTTER_TEST'] == 'true';

  if (isDesktop && !isTest) {
    try {
      await windowManager.ensureInitialized();
      const options = WindowOptions(
        minimumSize: Size(720, 600),
        size: Size(1100, 760),
        title: 'Photo Sorter',
      );
      await windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.center();
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (_) {
      // Ignore window_manager errors so tests and CI don't break.
    }
  }

  runApp(const ProviderScope(child: PhotoSorterApp()));
}

class PhotoSorterApp extends StatelessWidget {
  const PhotoSorterApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF4F8EF7);

    return MaterialApp(
      title: 'Photo Sorter',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const AppShell(),
    );
  }
}
