import 'package:flutter/widgets.dart';

import 'app_handle.dart';

/// Public session handle for Dashboard Mode (MOD-SESSION-002, FR-SESSION-005).
abstract class DashboardSession {
  AppHandle get handle;

  Widget buildWidget({required BuildContext context});

  /// Destroys the main Dashboard runtime and any slot runtimes that are not
  /// currently referenced by an App Mode [AppSession] (FR-DASH-008).
  Future<void> close();
}
