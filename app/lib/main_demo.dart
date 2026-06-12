// Demo entrypoint for visual verification under a headless display.
//
//   flutter run -d linux -t lib/main_demo.dart
//
// DEMO_SCREEN=review opens /tmp/demo_photos in the review screen;
// DEMO_SCREEN=sort (default) shows the sort screen.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'main.dart';
import 'state/cull_controller.dart';

void main() {
  runApp(const ProviderScope(child: _DemoLauncher()));
}

class _DemoLauncher extends ConsumerStatefulWidget {
  const _DemoLauncher();

  @override
  ConsumerState<_DemoLauncher> createState() => _DemoLauncherState();
}

class _DemoLauncherState extends ConsumerState<_DemoLauncher> {
  @override
  void initState() {
    super.initState();
    if (Platform.environment['DEMO_SCREEN'] == 'review') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(cullControllerProvider.notifier)
            .openFolder(Platform.environment['DEMO_DIR'] ?? '/tmp/demo_photos');
      });
    }
  }

  @override
  Widget build(BuildContext context) => const PhotoSorterApp();
}
