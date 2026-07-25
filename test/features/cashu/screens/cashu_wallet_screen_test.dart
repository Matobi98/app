import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/cashu/providers/cashu_wallet_provider.dart';
import 'package:mostro/features/cashu/screens/cashu_wallet_screen.dart';
import 'package:mostro/l10n/app_localizations.dart';
import 'package:mostro/src/rust/api/types.dart';

import '../../../support/provider_harness.dart';

/// Stands in for the Rust bridge. Every method the screen can reach is
/// overridden — an un-overridden one would call into Rust and hang the test
/// rather than fail it.
class _FakeController extends CashuWalletController {
  const _FakeController({this.connectError});

  final Object? connectError;

  @override
  Future<CashuWalletStatus> connect() async {
    if (connectError != null) throw connectError!;
    return _status(connected: true, balance: 0);
  }

  @override
  Future<BigInt> receiveToken(String encoded) async => BigInt.zero;

  @override
  Future<String> createToken(BigInt amountSats) async => 'cashuBtesttoken';

  @override
  Future<BigInt> checkProofsState() async => BigInt.zero;
}

CashuWalletStatus _status({required bool connected, required int balance}) {
  return CashuWalletStatus(
    connected: connected,
    mintUrl: connected ? 'https://mint.example.com' : null,
    balanceSats: BigInt.from(balance),
    missingCapabilities: const [],
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required CashuWalletStatus status,
  CashuWalletController controller = const _FakeController(),
}) async {
  final container = createContainer(overrides: [
    cashuWalletProvider.overrideWith((ref) => Stream.value(status)),
    cashuWalletControllerProvider.overrideWithValue(controller),
  ]);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildDarkTheme(),
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const CashuWalletScreen(),
      ),
    ),
  );

  // One frame to build, one for the stream and the post-frame connect.
  await tester.pump();
  await tester.pump();
}

void main() {
  group('CashuWalletScreen', () {
    testWidgets('a connected wallet shows its balance and mint', (tester) async {
      await _pump(tester, status: _status(connected: true, balance: 1234));

      expect(find.text('1234 Satoshis'), findsOneWidget);
      expect(find.text('Mint: https://mint.example.com'), findsOneWidget);
      expect(find.text('Not connected to a mint'), findsNothing);
    });

    testWidgets('a wallet that could not bind says so', (tester) async {
      await _pump(tester, status: _status(connected: false, balance: 0));

      expect(find.text('Not connected to a mint'), findsOneWidget);
      expect(find.text('0 Satoshis'), findsOneWidget);
    });

    testWidgets('sending is disabled with an empty wallet', (tester) async {
      // Nothing to send: offering the button would only produce a mint-side
      // failure the user cannot act on.
      await _pump(tester, status: _status(connected: true, balance: 0));

      final send = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Send'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(send.onPressed, isNull);
    });

    testWidgets('sending is enabled once there are funds', (tester) async {
      await _pump(tester, status: _status(connected: true, balance: 10));

      final send = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Send'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(send.onPressed, isNotNull);
    });

    testWidgets('a Rust marker is shown as a localized message, never raw',
        (tester) async {
      // The screen connects on its first frame; a Lightning node answers with
      // the gate marker.
      await _pump(
        tester,
        status: _status(connected: false, balance: 0),
        controller: const _FakeController(
          connectError: 'CashuNotEnabled: whatever Rust appended',
        ),
      );
      await tester.pump();

      expect(
        find.text('This Mostro node does not settle trades with Cashu.'),
        findsOneWidget,
      );
      expect(find.textContaining('CashuNotEnabled'), findsNothing);
    });

    testWidgets('an unrecognised failure falls back to the generic message',
        (tester) async {
      // A marker this build does not know must not leak an internal string.
      await _pump(
        tester,
        status: _status(connected: false, balance: 0),
        controller: const _FakeController(
          connectError: 'SomeFutureMarker: internal detail',
        ),
      );
      await tester.pump();

      expect(
        find.text('Something went wrong with the wallet. Please try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('SomeFutureMarker'), findsNothing);
    });
  });
}
