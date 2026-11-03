import 'package:flutter/material.dart';

/// Keep notifications transient even when they offer an action.
void showSpotifySnackBar(BuildContext context, String message, {SnackBarAction? action}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message), action: action,
    duration: const Duration(seconds: 4), persist: false,
  ));
}
