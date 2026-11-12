package com.archivetv.archive_tv_player

import android.app.UiModeManager
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Device class for ui/touch.dart: TV (Fire TV, Android TV, no touchscreen) keeps the D-pad UI.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "archivetv/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "isTv" -> {
                    val ui = getSystemService(UI_MODE_SERVICE) as UiModeManager
                    val pm = packageManager
                    result.success(
                        ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
                            pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
                            pm.hasSystemFeature("amazon.hardware.fire_tv") ||
                            !pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
                    )
                }
                "keepScreenOn" -> {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
