import 'package:flutter/material.dart';

/// The longest practical lifetime for a [SnackBar].
///
/// Flutter's [SnackBar] API requires a finite duration. Error feedback also
/// has an explicit close action and cannot be dismissed by swiping, so this
/// behaves as a persistent message from the user's perspective.
const sboxPersistentErrorSnackBarDuration = Duration(days: 365);

void showSboxFeedback(
  BuildContext context,
  String message, {
  bool error = false,
}) {
  final messenger = ScaffoldMessenger.of(context);
  // Keep the current message visible. In particular, a later status message
  // must not close an error before the user has acknowledged it.
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      duration: error
          ? sboxPersistentErrorSnackBarDuration
          : const Duration(seconds: 4),
      dismissDirection: error ? DismissDirection.none : null,
      action: error
          ? SnackBarAction(
              label: '关闭',
              textColor: Theme.of(context).colorScheme.onError,
              onPressed: () => messenger.hideCurrentSnackBar(
                reason: SnackBarClosedReason.action,
              ),
            )
          : null,
    ),
  );
}
