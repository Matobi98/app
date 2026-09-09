import 'package:flutter/material.dart';

/// Shown when startup cannot reach `runApp`.
///
/// Deliberately dependency-free: no localization, no app theme, no Rust, no
/// SharedPreferences. Any of those can be the thing that failed, and a rescue
/// surface that needs what broke is a second blank page (#227, #389).
///
/// [step] names the startup step that threw, phrased to read inside the
/// sentence below ("It failed while loading the engine."). That name is the
/// whole point of this screen: "Mostro won't open" is unactionable, "it failed
/// loading the engine" is a starting point — both for the person reporting it
/// and for whoever reads the report.
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key, required this.step});

  final String step;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // Every route resolves here rather than using `home:`. On the web the
      // initial route comes from the browser's URL, and a startup failure is
      // most often met on a reload of some deep path — which `home:` alone
      // answers with "Could not navigate to initial route" in the console
      // before falling back. Harmless, but this screen exists to make a failed
      // startup legible; it should not add noise of its own to the one log the
      // person reporting it is about to read.
      onGenerateRoute: (_) => MaterialPageRoute<void>(builder: _buildBody),
    );
  }

  Widget _buildBody(BuildContext context) {
    return Scaffold(
      // Hard-coded rather than taken from the app theme: the theme is built
      // from settings this screen exists to survive the loss of.
      backgroundColor: const Color(0xFF1D212C),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Mostro could not start',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'It failed while $step.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFB0B6C3), fontSize: 15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
