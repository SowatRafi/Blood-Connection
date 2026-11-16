package org.bindubashini.bloodconnection

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Flutter owns the shared experience; no native phone-number or contact integration is needed.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // New Android releases can require the chosen push companion to be opened before it can run its service.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bloodconnection/notifications")
            .setMethodCallHandler { call, result ->
                if (call.method != "openDistributor") {
                    result.notImplemented()
                } else {
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
