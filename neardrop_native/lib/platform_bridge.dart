import 'dart:io';

import 'package:flutter/services.dart';

/// Android must hold a WifiManager.MulticastLock while LAN discovery is active.
class DiscoveryPlatform {
  static const _channel = MethodChannel('neardrop/platform');

  static Future<void> acquire() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('acquireMulticast');
    }
  }

  static Future<void> release() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('releaseMulticast');
    }
  }

  /// Returns the user-visible shared-storage folder used for Android receives.
  /// On Android 11+ the native side opens the app's "all files access" page
  /// and throws a clear error when that special permission still needs approval.
  static Future<String?> publicReceiveDirectory() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<String>('preparePublicReceiveDirectory');
  }
}
