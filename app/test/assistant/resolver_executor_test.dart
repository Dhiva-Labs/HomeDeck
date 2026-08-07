import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/assistant/device_resolver.dart';
import 'package:home_deck/assistant/intent_executor.dart';
import 'package:home_deck/assistant/nlu/nlu_engine.dart';
import 'package:home_deck/assistant/nlu/rules_nlu.dart';
import 'package:home_deck/connectors/connector.dart';
import 'package:home_deck/models/device.dart';
import 'package:home_deck/services/connectors_service.dart';
import 'package:home_deck/services/device_registry.dart';

/// Records every action instead of talking to hardware.
class FakeConnector extends Connector {
  FakeConnector(super.registry);

  final invocations = <(String deviceId, DeviceAction action)>[];

  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> invoke(Device device, DeviceAction action) async {
    invocations.add((device.id, action));
  }
}

Device dev(String id, String name, DeviceKind kind, {String? room}) => Device(
      id: 'fake:$id',
      connectorId: 'fake',
      name: name,
      kind: kind,
      room: room,
      capabilities: {DeviceCapability.toggle, DeviceCapability.brightness},
      state: {'on': false, 'brightness': 50},
    );

void main() {
  late DeviceRegistry registry;
  late FakeConnector connector;
  late IntentExecutor executor;
  const nlu = RulesNlu();

  NluContext ctx() => NluContext(
        deviceNames: registry.devices.map((d) => d.name).toList(),
        roomNames: registry.rooms,
      );

  setUp(() {
    registry = DeviceRegistry();
    connector = FakeConnector(registry);
    registry.addRoom('Kitchen');
    registry.addRoom('Bedroom');
    registry.upsertAll([
      dev('1', 'Kitchen Light', DeviceKind.light, room: 'Kitchen'),
      dev('2', 'Desk Lamp', DeviceKind.light, room: 'Bedroom'),
      dev('3', 'Bedroom Light', DeviceKind.light, room: 'Bedroom'),
      dev('4', 'Coffee Maker', DeviceKind.outlet, room: 'Kitchen'),
    ]);
    executor = IntentExecutor(
      ConnectorsService([connector]),
      DeviceResolver(registry),
    );
  });

  Future<ExecutionResult> run(String utterance) =>
      executor.execute(nlu.parse(utterance, ctx()));

  test('turn off all the lights hits every light and no outlet', () async {
    final result = await run('turn off all the lights');
    expect(result.ok, isTrue);
    expect(connector.invocations.length, 3);
    expect(connector.invocations.every((i) => i.$2.name == 'turn_off'), isTrue);
    expect(connector.invocations.any((i) => i.$1 == 'fake:4'), isFalse);
  });

  test('room scoping: turn on the kitchen lights', () async {
    final result = await run('turn on the kitchen lights');
    expect(result.ok, isTrue);
    expect(connector.invocations.map((i) => i.$1), ['fake:1']);
  });

  test('fuzzy name: turn on the desk lamp', () async {
    await run('turn on the desk lamp');
    expect(connector.invocations.map((i) => i.$1), ['fake:2']);
  });

  test('brightness lands as 0-100 set_brightness', () async {
    await run('set the desk lamp to 40 percent');
    final (_, action) = connector.invocations.single;
    expect(action.name, 'set_brightness');
    expect(action.args['value'], 40);
  });

  test('same-kind multi-match acts on all instead of asking', () async {
    // Google Assistant contract: "turn on the light" with three lights
    // turns on three lights — no quiz.
    final result = await run('turn on the light');
    expect(result.ok, isTrue);
    expect(result.needsDisambiguation, isFalse);
    expect(connector.invocations.length, 3);
  });

  test('mixed-kind ambiguity still asks', () async {
    registry.upsertAll([
      dev('5', 'Desk Fan', DeviceKind.outlet, room: 'Bedroom'),
    ]);
    // "the desk" matches Desk Lamp (light) and Desk Fan (outlet): guessing
    // here actuates the wrong class of hardware, so the assistant asks.
    final result = await run('turn on the desk');
    expect(result.needsDisambiguation, isTrue);
    expect(connector.invocations, isEmpty);
    expect(result.spoken, contains('Which one'));
  });

  test('query results are marked speakable', () async {
    final result = await run('is the desk lamp on');
    expect(result.ok, isTrue);
    expect(result.isQueryAnswer, isTrue);
  });

  test('unknown device is reported, not silently dropped', () async {
    final result = await run('turn on the disco ball');
    expect(result.ok, isFalse);
    expect(connector.invocations, isEmpty);
  });

  test('offline devices are never targeted', () async {
    registry.updateState('fake:2', {}, online: false);
    // Registry list will still include it; resolver filters on online.
    final result = await run('turn on the desk lamp');
    expect(connector.invocations, isEmpty);
    expect(result.ok, isFalse);
  });
}
