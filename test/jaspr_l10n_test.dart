import 'package:jaspr_l10n/jaspr_l10n.dart';
import 'package:test/test.dart';

void main() {
  group('printHelp', () {
    test('prints usage information', () {
      // Just check that it doesn't throw
      expect(() => printHelp('src', 'out.dart', 'out.ts'), returnsNormally);
    });
  });

  group('L10nModel and L10nEntry', () {
    test('L10nModel stores locales and entries', () {
      final model = L10nModel(locales: ['en', 'de'], entries: {});
      expect(model.locales, containsAll(['en', 'de']));
      expect(model.entries, isEmpty);
    });
    test('L10nEntry stores key and values', () {
      final entry = L10nEntry('greeting');
      entry.valuesByLocale['en'] = 'Hello';
      expect(entry.key, 'greeting');
      expect(entry.valuesByLocale['en'], 'Hello');
      expect(entry.placeholders, isEmpty);
    });
  });

  group('inferPlaceholdersFromAnyValue', () {
    test('extracts placeholders from values', () {
      final values = ['Hello {name}', 'Welcome {name} to {place}'];
      final result = inferPlaceholdersFromAnyValue(values);
      expect(result, containsAll(['name', 'place']));
    });
    test('returns empty set if no placeholders', () {
      final values = ['Hello', 'World'];
      final result = inferPlaceholdersFromAnyValue(values);
      expect(result, isEmpty);
    });
  });

  group('inferLocaleFromFilename', () {
    test('extracts locale from filename', () {
      expect(inferLocaleFromFilename('app_en.arb'), 'en');
      expect(inferLocaleFromFilename('foo_bar_de-DE.arb'), 'de-DE');
    });
    test('throws if cannot infer', () {
      expect(() => inferLocaleFromFilename('foo.arb'), throwsException);
    });
  });

  group('buildModel', () {
    test('builds model from bundles', () {
      final bundles = {
        'en': {
          'greet': 'Hello',
          '@greet': {'placeholders': {}},
        },
        'de': {
          'greet': 'Hallo',
          '@greet': {'placeholders': {}},
        },
      };
      final model = buildModel(bundles);
      expect(model.locales, containsAll(['en', 'de']));
      expect(model.entries['greet']?.valuesByLocale['en'], 'Hello');
      expect(model.entries['greet']?.valuesByLocale['de'], 'Hallo');
    });
  });

  group('validateModel', () {
    test('throws if missing translation', () {
      final model = buildModel({
        'en': {'greet': 'Hello'},
        'de': {},
      });
      expect(() => validateModel(model), throwsException);
    });
    test('fills missing with fallback', () {
      final model = buildModel({
        'en': {'greet': 'Hello'},
        'de': {},
      });
      expect(() => validateModel(model, fallbackLang: 'en'), returnsNormally);
      expect(model.entries['greet']?.valuesByLocale['de'], 'Hello');
    });
    test('infers placeholders if missing', () {
      final model = buildModel({
        'en': {'greet': 'Hello {name}'},
        'de': {'greet': 'Hallo {name}'},
      });
      validateModel(model);
      expect(model.entries['greet']?.placeholders, contains('name'));
    });
  });

  group('generateDart', () {
    test('generates Dart code', () {
      final model = buildModel({
        'en': {'greet': 'Hello'},
        'de': {'greet': 'Hallo'},
      });
      final code = generateDart(model);
      expect(code, contains('class L10n'));
      expect(code, contains("'greet'"));
    });
  });

  group('generateTs', () {
    test('generates TypeScript code', () {
      final model = buildModel({
        'en': {'greet': 'Hello'},
        'de': {'greet': 'Hallo'},
      });
      final code = generateTs(model);
      expect(code, contains('export function t'));
      expect(code, contains("'greet'"));
    });
  });

  group('toSafeDartIdentifier', () {
    test('converts to safe identifier', () {
      expect(toSafeDartIdentifier('foo-bar'), 'foo_bar');
      expect(toSafeDartIdentifier('123abc'), 'k_123abc');
    });
  });

  group('escapeDart and escapeTs', () {
    test('escapes Dart and TS strings', () {
      expect(escapeDart("a'b\nc"), "a'b\\nc");
      expect(escapeTs("a'b\nc"), "a'b\\nc");
    });
  });
}
