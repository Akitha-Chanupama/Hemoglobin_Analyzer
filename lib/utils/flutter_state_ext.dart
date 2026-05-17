import 'package:flutter/widgets.dart';

/// Extension to safely call setState only when the widget is still mounted
extension FlutterStateExtension<T extends StatefulWidget> on State<T> {
  /// Calls setState only if the widget is still mounted
  void setStateIfMounted(VoidCallback fn) {
    if (mounted) {
      // ignore: invalid_use_of_protected_member
      setState(fn);
    }
  }
}
