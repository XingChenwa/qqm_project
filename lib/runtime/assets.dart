export 'package:flutter/services.dart'
    if (dart.library.ui) 'package:flutter/services.dart'
    if (dart.library.io) 'assets_server.dart'
    show rootBundle;
