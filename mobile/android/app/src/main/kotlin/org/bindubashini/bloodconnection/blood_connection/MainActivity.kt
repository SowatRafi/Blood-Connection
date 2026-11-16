package org.bindubashini.bloodconnection

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Hosts Flutter and the narrow bridge for opening the selected UnifiedPush companion. */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // New Android releases can require the chosen push companion to be opened before it can run its service.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bloodconnection/notifications")
            .setMethodCallHandler { call, result ->
                if (call.method != "openDistributor") {
                    result.notImplemented()
                } else {
                    // Resolve a normal launcher activity instead of accepting an arbitrary external intent.
                    val distributor = call.argument<String>("package")
                    val intent = distributor?.let { packageManager.getLaunchIntentForPackage(it) }
                    if (intent == null) result.error("unavailable", "Notification companion is not installed", null)
                    else {
                        startActivity(intent)
                        result.success(null)
                    }
                }
            }
    }
}
