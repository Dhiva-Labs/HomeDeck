import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:media_kit/media_kit.dart';

import 'connectors/ha/ha_connector.dart';
import 'connectors/netscan/netscan_connector.dart';
import 'screens/home_shell.dart';
import 'screens/onboarding_screen.dart';
import 'services/camera_store.dart';
import 'services/connectors_service.dart';
import 'services/device_registry.dart';
import 'services/settings_store.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final settings = await SettingsStore.load();
  final registry = DeviceRegistry();
  await registry.load();
  final cameras = CameraStore();
  await cameras.load();

  final ha = HaConnector(registry);
  await ha.configure(baseUrl: settings.haUrl, token: settings.haToken);

  final connectors = ConnectorsService([
    NetscanConnector(registry),
    ha,
  ]);
  unawaited(connectors.startAll());

  if (settings.keepScreenOn) {
    WakelockPlus.enable();
  }

  runApp(HomeDeckApp(
    settings: settings,
    registry: registry,
    cameras: cameras,
    connectors: connectors,
  ));
}

class HomeDeckApp extends StatelessWidget {
  const HomeDeckApp({
    super.key,
    required this.settings,
    required this.registry,
    required this.cameras,
    required this.connectors,
  });

  final SettingsStore settings;
  final DeviceRegistry registry;
  final CameraStore cameras;
  final ConnectorsService connectors;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: registry),
        ChangeNotifierProvider.value(value: cameras),
        ChangeNotifierProvider.value(value: connectors),
        ChangeNotifierProvider.value(
            value: connectors.get<NetscanConnector>('netscan')!),
        ChangeNotifierProvider.value(
            value: connectors.get<HaConnector>('ha')!),
      ],
      child: Consumer<SettingsStore>(
        builder: (context, settings, _) => MaterialApp(
          title: 'HomeDeck',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(lowFx: settings.lowFx),
          home: settings.onboarded
              ? const HomeShell()
              : const OnboardingScreen(),
        ),
      ),
    );
  }
}
