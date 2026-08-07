import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:media_kit/media_kit.dart';

import 'assistant/assistant_boot.dart';
import 'assistant/assistant_service.dart';
import 'assistant/device_resolver.dart';
import 'assistant/intent_executor.dart';
import 'assistant/nlu/rules_nlu.dart';
import 'assistant/voice/impl/stt_recognizer.dart';
import 'assistant/voice/impl/tts_synthesizer.dart';
import 'connectors/googlehome/googlehome_connector.dart';
import 'connectors/ha/ha_connector.dart';
import 'connectors/hub/hub_connector.dart';
import 'connectors/hue/hue_connector.dart';
import 'connectors/mqtt/mqtt_connector.dart';
import 'connectors/netscan/netscan_connector.dart';
import 'screens/home_shell.dart';
import 'screens/onboarding_screen.dart';
import 'services/camera_store.dart';
import 'services/connectors_service.dart';
import 'services/device_registry.dart';
import 'services/settings_store.dart';
import 'theme.dart';
import 'widgets/night_dimmer.dart';

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

  final mqtt = MqttConnector(registry);
  await mqtt.configure(
    host: settings.mqttBroker,
    port: settings.mqttPort,
    username: settings.mqttUsername,
    password: settings.mqttPassword,
  );

  final hub = HubConnector(registry);
  await hub.configure(baseUrl: settings.hubUrl);

  final hue = HueConnector(registry);
  await hue.configure(
    bridgeIp: settings.hueBridgeIp,
    applicationKey: settings.hueAppKey,
  );

  final ghome = GoogleHomeConnector(registry);
  await ghome.configure(enabled: false); // needs Developer Console setup

  final connectors = ConnectorsService([
    NetscanConnector(registry),
    ha,
    mqtt,
    hub,
    hue,
    ghome,
  ]);
  unawaited(connectors.startAll());

  if (settings.keepScreenOn) {
    WakelockPlus.enable();
  }

  final assistant = AssistantService(
    registry: registry,
    nlu: const RulesNlu(),
    executor: IntentExecutor(connectors, DeviceResolver(registry)),
    recognizer: SttSpeechRecognizer(),
    synthesizer: FlutterTtsSynthesizer()..volume = settings.ttsVolume,
  );
  // Hotword startup happens after the first frame, off the critical path.
  unawaited(applyAssistantSettings(assistant, settings));

  runApp(HomeDeckApp(
    settings: settings,
    registry: registry,
    cameras: cameras,
    connectors: connectors,
    assistant: assistant,
  ));
}

class HomeDeckApp extends StatelessWidget {
  const HomeDeckApp({
    super.key,
    required this.settings,
    required this.registry,
    required this.cameras,
    required this.connectors,
    required this.assistant,
  });

  final SettingsStore settings;
  final DeviceRegistry registry;
  final CameraStore cameras;
  final ConnectorsService connectors;
  final AssistantService assistant;

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
        ChangeNotifierProvider.value(
            value: connectors.get<MqttConnector>('mqtt')!),
        ChangeNotifierProvider.value(
            value: connectors.get<HubConnector>('hub')!),
        ChangeNotifierProvider.value(
            value: connectors.get<HueConnector>('hue')!),
        ChangeNotifierProvider.value(
            value: connectors.get<GoogleHomeConnector>('ghome')!),
        ChangeNotifierProvider.value(value: assistant),
      ],
      child: Consumer<SettingsStore>(
        builder: (context, settings, _) => MaterialApp(
          title: 'HomeDeck',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(lowFx: settings.lowFx),
          home: settings.onboarded
              ? const NightDimmer(child: HomeShell())
              : const OnboardingScreen(),
        ),
      ),
    );
  }
}
