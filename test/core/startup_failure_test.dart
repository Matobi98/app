import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/startup_failure.dart';

void main() {
  group('StartupFailureApp', () {
    testWidgets('names the step that failed', (tester) async {
      await tester.pumpWidget(
        const StartupFailureApp(step: 'loading the engine'),
      );

      // The step name is the reason this screen exists: "Mostro won't open" is
      // unactionable, "it failed loading the engine" is where to look. A
      // refactor that drops it leaves a screen no more useful than the blank
      // page it replaced (#389).
      expect(find.textContaining('loading the engine'), findsOneWidget);
      expect(find.text('Mostro could not start'), findsOneWidget);
    });

    testWidgets('says which step, not just that one failed', (tester) async {
      await tester.pumpWidget(
        const StartupFailureApp(step: 'reading your settings'),
      );
      expect(find.textContaining('reading your settings'), findsOneWidget);
      expect(find.textContaining('loading the engine'), findsNothing);
    });

    testWidgets('answers a deep initial route, not just "/"', (tester) async {
      // On the web the initial route is the browser's URL, and a startup
      // failure is usually met on a reload of some deep path. With `home:`
      // alone that logged "Could not navigate to initial route" before falling
      // back — noise in the one log a reporter is about to read.
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(),
          child: StartupFailureApp(step: 'loading the engine'),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Mostro could not start'), findsOneWidget);
    });

    testWidgets('renders without any app dependency', (tester) async {
      // No ProviderScope, no AppLocalizations, no theme, no Rust bridge — this
      // pump is the assertion. Any of those could be what failed, so a rescue
      // surface that needs one is a second blank page.
      await tester.pumpWidget(const StartupFailureApp(step: 'starting up'));

      expect(tester.takeException(), isNull);
      expect(find.byType(MaterialApp), findsOneWidget);
    });
  });
}
