// File generated for Firebase project egg-system-c36f5 (706362147152).
// Do not run `flutterfire configure` and create a new project.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.windows:
        return windows;
      default:
        return web;
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBBl_A2RIuNbRrCD94EX7bRbcBB--989QQ',
    appId: '1:706362147152:web:8904229c01df9106cbac55',
    messagingSenderId: '706362147152',
    projectId: 'egg-system-c36f5',
    authDomain: 'egg-system-c36f5.firebaseapp.com',
    storageBucket: 'egg-system-c36f5.firebasestorage.app',
    measurementId: 'G-JPZ3NC2E43',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyA1HNb83G70H9nWRnAEMuvACadR7oN4KPg',
    appId: '1:706362147152:android:c16f163414da3683cbac55',
    messagingSenderId: '706362147152',
    projectId: 'egg-system-c36f5',
    storageBucket: 'egg-system-c36f5.firebasestorage.app',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyBBl_A2RIuNbRrCD94EX7bRbcBB--989QQ',
    appId: '1:706362147152:web:8904229c01df9106cbac55',
    messagingSenderId: '706362147152',
    projectId: 'egg-system-c36f5',
    authDomain: 'egg-system-c36f5.firebaseapp.com',
    storageBucket: 'egg-system-c36f5.firebasestorage.app',
    measurementId: 'G-JPZ3NC2E43',
  );
}
