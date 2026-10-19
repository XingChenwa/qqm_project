// The server and Flutter clients share the same bot/plugin implementation.
export 'package:flutter/foundation.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart'
    if (dart.library.io) 'notifier_server.dart'
    show ChangeNotifier;
