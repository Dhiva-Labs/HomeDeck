import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/assistant/intent.dart';
import 'package:home_deck/assistant/nlu/nlu_engine.dart';
import 'package:home_deck/assistant/nlu/rules_nlu.dart';
import 'package:home_deck/models/device.dart';

void main() {
  const nlu = RulesNlu();
  const ctx = NluContext(
    deviceNames: ['Desk Lamp', 'Kitchen Light', 'Living Room TV', 'Thermostat'],
    roomNames: ['Kitchen', 'Living Room', 'Bedroom'],
    sceneNames: ['Movie Night'],
  );

  Intent parse(String s) => nlu.parse(s, ctx);

  group('on/off', () {
    test('turn on the desk lamp', () {
      final i = parse('turn on the desk lamp');
      expect(i.type, IntentType.turnOn);
      expect(i.target.phrase, 'desk lamp');
    });

    test('turn off the kitchen lights', () {
      final i = parse('turn off the kitchen lights');
      expect(i.type, IntentType.turnOff);
      expect(i.target.room, 'Kitchen');
      expect(i.target.kind, DeviceKind.light);
      expect(i.target.all, isTrue);
    });

    test('switch off everything in the bedroom', () {
      final i = parse('switch off everything in the bedroom');
      expect(i.type, IntentType.turnOff);
      expect(i.target.room, 'Bedroom');
      expect(i.target.all, isTrue);
    });

    test('trailing state: kitchen light on', () {
      final i = parse('kitchen light on');
      expect(i.type, IntentType.turnOn);
      expect(i.target.room, 'Kitchen');
    });

    test('politeness is stripped', () {
      final i = parse('please could you turn off the desk lamp');
      expect(i.type, IntentType.turnOff);
      expect(i.target.phrase, 'desk lamp');
    });
  });

  group('brightness', () {
    test('set the desk lamp to 40 percent', () {
      final i = parse('set the desk lamp to 40 percent');
      expect(i.type, IntentType.setBrightness);
      expect(i.args['value'], 40);
      expect(i.target.phrase, 'desk lamp');
    });

    test('number words: set the lamp to fifty percent', () {
      final i = parse('set the desk lamp to fifty percent');
      expect(i.type, IntentType.setBrightness);
      expect(i.args['value'], 50);
    });

    test('compound number words: twenty five percent', () {
      final i = parse('set the desk lamp to twenty five percent');
      expect(i.args['value'], 25);
    });

    test('dim the lights = relative decrease', () {
      final i = parse('dim the lights');
      expect(i.type, IntentType.changeBrightness);
      expect((i.args['delta'] as int).isNegative, isTrue);
      expect(i.target.kind, DeviceKind.light);
    });

    test('turn on the lamp at 70 percent', () {
      final i = parse('turn on the desk lamp 70 percent');
      expect(i.type, IntentType.setBrightness);
      expect(i.args['value'], 70);
    });
  });

  group('temperature', () {
    test('set the thermostat to 21 degrees', () {
      final i = parse('set the thermostat to 21 degrees');
      expect(i.type, IntentType.setTemperature);
      expect(i.args['value'], 21);
      expect(i.target.kind, DeviceKind.climate);
    });

    test('bare number: set the thermostat to 22', () {
      final i = parse('set the thermostat to 22');
      // Bare number with a climate target reads as temperature only via
      // reconciliation; accept either set intent as long as value survives.
      expect(i.args['value'], 22);
    });

    test('make it warmer', () {
      final i = parse('make it warmer');
      expect(i.type, IntentType.changeTemperature);
      expect((i.args['delta'] as num) > 0, isTrue);
    });
  });

  group('other intents', () {
    test('query: is the kitchen light on', () {
      final i = parse('is the kitchen light on');
      expect(i.type, IntentType.query);
    });

    test('wake the computer', () {
      final i = parse('wake up the computer');
      expect(i.type, IntentType.wakeComputer);
      expect(i.target.kind, DeviceKind.computer);
    });

    test('show me the front door camera', () {
      final i = parse('show me the front door camera');
      expect(i.type, IntentType.showCamera);
      expect(i.target.kind, DeviceKind.camera);
    });

    test('stop', () {
      expect(parse('never mind').type, IntentType.stop);
      expect(parse('cancel').type, IntentType.stop);
    });

    test('gibberish is unknown', () {
      expect(parse('purple monkey dishwasher').type, IntentType.unknown);
    });

    test('verb without target keeps low confidence', () {
      final i = parse('turn off');
      expect(i.type, IntentType.turnOff);
      expect(i.confidence, lessThan(0.5));
    });
  });
}
