import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static guards over `lib/core/app_bootstrap.dart`.
///
/// The startup sequence cannot be exercised in a unit test — reaching it needs
/// Rust, preferences and relays, i.e. the whole app assembled to watch it not
/// assemble. What can be checked is the shape it must keep, in the spirit of
/// test/web/pages_bundle_test.dart: each of these, when wrong, is silent.
void main() {
  final source = File('lib/core/app_bootstrap.dart').readAsStringSync();

  group('startup guard (#389)', () {
    test('a failure still reaches runApp', () {
      // The entire fix in one line. Without this the sequence throws, runApp
      // never runs, and Flutter paints nothing — not a broken page, an absent
      // one, with no message anywhere (#227).
      expect(
        source.contains('runApp(StartupFailureApp('),
        isTrue,
        reason:
            'the last-resort catch must call runApp with the failure '
            'surface; without it a failed startup is a blank page again',
      );
    });

    test('the failure surface is told which step failed', () {
      expect(
        RegExp(
          r'runApp\(StartupFailureApp\(step: _currentStep\)\)',
        ).hasMatch(source),
        isTrue,
        reason:
            'the screen must name the failing step — a generic "could not '
            'start" is no more actionable than the blank page it replaces',
      );
    });

    test('every optional step is named where it is guarded', () {
      // _optional takes the name it logs and reports, so a step added with an
      // empty or placeholder name degrades invisibly.
      final names =
          RegExp(
            r"_optional\('([^']*)'",
          ).allMatches(source).map((m) => m.group(1)!).toList();
      expect(names, isNotEmpty, reason: 'the optional steps went missing');
      for (final name in names) {
        expect(
          name.trim(),
          isNotEmpty,
          reason: 'an optional step was guarded without a name',
        );
      }
    });

    test('the local database is opened on the web too (#408)', () {
      // Before #408 this call sat inside `if (!kIsWeb)`, because the web store
      // was a stub. It is not any more: web persistence lives there now, so
      // re-adding that guard — the easy way to resolve a conflict in this
      // file — would quietly take out every web feature built on top of it.
      final initDbAt = source.indexOf('rust_api.initDb(');
      expect(
        initDbAt,
        greaterThanOrEqualTo(0),
        reason: 'the database is never initialised',
      );

      final before = source.substring(0, initDbAt);
      final enclosingWebGuard =
          RegExp(
            r'if\s*\(\s*!\s*kIsWeb\s*\)\s*\{',
          ).allMatches(before).isNotEmpty;
      expect(
        enclosingWebGuard,
        isFalse,
        reason:
            'initDb must not be skipped on the web: since #408 that is '
            'where web persistence lives (#233)',
      );
    });
  });
}
