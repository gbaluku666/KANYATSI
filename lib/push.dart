// Push notifications for a CLOSED app.
// This is the "off" version. When a Firebase file is added to the repository
// (firebase/google-services.json) the build swaps this file for push_firebase.dart.txt.
class PushService {
  static Future<void> init(Future<void> Function(String token) onToken,
      void Function(String title, String body) onForeground) async {}
}
