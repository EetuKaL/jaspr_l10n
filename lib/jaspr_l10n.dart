// tool/l10n_gen.dart
import 'dart:convert';
import 'dart:io';

const kFrom = 'lib/l10n';
const kDartOut = 'lib/generated/l10n.g.dart';
const kJsOut = 'web/generated/l10n.js';

void printHelp() {
  print('Usage: dart tool/l10n_gen.dart');
  print('Generates Localization files from .arb bundles, one for Dart and one for TypeScript.');
  print('Parameters:');
  print(' -a/--arbs <Directory>   Source directory for .arb files (default: $kFrom)');
  print(' -d/--dart-out <File>    Output Dart file (default: $kDartOut)');
  print(' -j/--js-out <File>      Output JavaScript file (default: $kJsOut)');
  print(
    ' -f/--fallback-language  Fallback language code to use if some locale is missing a key (e.g. "en"), Otherwise arbs must have same keys, or generation will fail.',
  );
}

Future<Map<String, Map<String, dynamic>>> loadArbBundles(Directory dir) async {
  final result = <String, Map<String, dynamic>>{};
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.arb')).toList();

  for (final f in files) {
    final jsonMap = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    final locale = (jsonMap['@@locale'] ?? inferLocaleFromFilename(f.path)) as String;
    result[locale] = jsonMap;
  }
  return result;
}

String inferLocaleFromFilename(String path) {
  final name = path.split(Platform.pathSeparator).last;
  final m = RegExp(r'_([a-z]{2}(-[A-Z]{2})?)\.arb$').firstMatch(name);
  if (m == null) throw Exception('Cannot infer locale from: $name');
  return m.group(1)!;
}

L10nModel buildModel(Map<String, Map<String, dynamic>> bundles) {
  final locales = bundles.keys.toList()..sort();
  final entries = <String, L10nEntry>{};

  for (final locale in locales) {
    final map = bundles[locale]!;
    for (final kv in map.entries) {
      final key = kv.key;
      if (key.startsWith('@')) continue; // metadata
      final value = kv.value;
      if (value is! String) continue;

      final entry = entries.putIfAbsent(key, () => L10nEntry(key));
      entry.valuesByLocale[locale] = value;
    }
  }

  for (final locale in locales) {
    final map = bundles[locale]!;
    for (final kv in map.entries) {
      if (!kv.key.startsWith('@') || kv.key.startsWith('@@')) continue;
      final key = kv.key.substring(1);
      final meta = kv.value;
      if (meta is Map && meta['placeholders'] is Map) {
        final placeholders = (meta['placeholders'] as Map).keys.cast<String>();
        entries[key]?.placeholders.addAll(placeholders);
      }
    }
  }

  return L10nModel(locales: locales, entries: entries);
}

void validateModel(L10nModel model, {String? fallbackLang}) {
  for (final e in model.entries.values) {
    for (final loc in model.locales) {
      if (!e.valuesByLocale.containsKey(loc)) {
        if (fallbackLang != null && e.valuesByLocale.containsKey(fallbackLang)) {
          e.valuesByLocale[loc] = e.valuesByLocale[fallbackLang]!;
          continue;
        }
        throw Exception('Missing "$loc" translation for key: ${e.key}');
      }
    }
    final inferred = inferPlaceholdersFromAnyValue(e.valuesByLocale.values);
    if (e.placeholders.isEmpty) e.placeholders.addAll(inferred);
  }
}

Set<String> inferPlaceholdersFromAnyValue(Iterable<String> values) {
  final set = <String>{};
  final re = RegExp(r'\{([a-zA-Z_][a-zA-Z0-9_]*)\}');
  for (final v in values) {
    for (final m in re.allMatches(v)) {
      set.add(m.group(1)!);
    }
  }
  return set;
}

String generateDart(L10nModel model) {
  final b = StringBuffer();
  b.writeln('// GENERATED - do not edit.');
  b.writeln("const supportedLocales = <String>[${model.locales.map((l) => "'$l'").join(', ')}];");

  b.writeln('const _strings = <String, Map<String, String>>{');
  for (final e in model.entries.values) {
    b.writeln("  '${e.key}': {");
    for (final loc in model.locales) {
      final v = escapeDart(e.valuesByLocale[loc]!);
      b.writeln("    '$loc': '$v',");
    }
    b.writeln('  },');
  }
  b.writeln('};');

  b.writeln('class L10n {');
  b.writeln('  final String locale;');
  b.writeln('  const L10n(this.locale);');

  b.writeln('  String t(String key, [Map<String, Object?> params = const {}]) {');
  b.writeln('    final s = _strings[key]?[locale] ?? _strings[key]?["en"] ?? key;');
  b.writeln('    return _interpolate(s, params);');
  b.writeln('  }');

  b.writeln('  static String _interpolate(String s, Map<String, Object?> params) {');
  b.writeln('    var out = s;');
  b.writeln(r'    params.forEach((k, v) { out = out.replaceAll("{$k}", "\${v ?? ""}"); });');
  b.writeln('    return out;');
  b.writeln('  }');

  for (final e in model.entries.values) {
    final dartName = toSafeDartIdentifier(e.key);
    if (e.placeholders.isEmpty) {
      b.writeln('  String get $dartName => t(\'${e.key}\');');
    } else {
      final paramsSig = e.placeholders.map((p) => 'required Object $p').join(', ');
      final paramsMap = e.placeholders.map((p) => "'$p': $p").join(', ');
      b.writeln('  String $dartName({$paramsSig}) => t(\'${e.key}\', {$paramsMap});');
    }
  }

  b.writeln('}');
  return b.toString();
}

String generateJs(L10nModel model) {
  final b = StringBuffer();
  b.writeln('// GENERATED - do not edit.');

  // locales array
  b.writeln('export const locales = [${model.locales.map((l) => "'$l'").join(', ')}];');

  final keys = model.entries.keys.toList()..sort();

  // strings object
  b.writeln('const strings = {');
  for (final key in keys) {
    b.writeln("  '$key': {");
    for (final loc in model.locales) {
      final v = escapeJs(model.entries[key]!.valuesByLocale[loc]!);
      b.writeln("    '$loc': '$v',");
    }
    b.writeln('  },');
  }
  b.writeln('};');

  // createT(locale) -> (key, params) => string
  b.writeln('export function createT(locale) {');
  b.writeln('  const loc = (locales.includes(locale) ? locale : "en");');
  b.writeln('  return function t(key, params = {}) {');
  b.writeln(
    '    const s = (strings[key] && strings[key][loc])'
    ' || (strings[key] && strings[key]["en"])'
    ' || key;',
  );
  b.writeln('    return interpolate(s, params);');
  b.writeln('  };');
  b.writeln('}');

  b.writeln('function interpolate(s, params) {');
  b.writeln(
    '  return String(s).replace(/\\{([a-zA-Z_][a-zA-Z0-9_]*)\\}/g, (_, k) => String((params && params[k] != null) ? params[k] : ""));',
  );
  b.writeln('}');
  return b.toString();
}

String toSafeDartIdentifier(String key) {
  final cleaned = key.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
  if (RegExp(r'^[0-9]').hasMatch(cleaned)) return 'k_$cleaned';
  return cleaned;
}

String escapeDart(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', r'\n');

String escapeJs(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', r'\n');

class L10nModel {
  final List<String> locales;
  final Map<String, L10nEntry> entries;
  L10nModel({required this.locales, required this.entries});
}

class L10nEntry {
  final String key;
  final Map<String, String> valuesByLocale = {};
  final Set<String> placeholders = {};
  L10nEntry(this.key);
}
