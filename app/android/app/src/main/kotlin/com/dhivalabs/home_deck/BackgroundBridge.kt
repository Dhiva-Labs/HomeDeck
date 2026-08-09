package com.dhivalabs.home_deck

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `MethodChannel('homedeck/background')` — lets Dart keep the wake engine
 * alive off-screen:
 *
 * - startListening / stopListening: run/stop [WakeWordService].
 * - isIgnoringBatteryOptimizations / requestIgnoreBatteryOptimizations:
 *   without the exemption, aggressive OEMs (Xiaomi, Samsung…) kill the
 *   service minutes after the screen locks. The request fires the system
 *   dialog — granting is the user's choice.
 */
class BackgroundBridge(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "homedeck/background"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startListening" -> {
                WakeWordService.start(activity)
                result.success(true)
            }
            "stopListening" -> {
                WakeWordService.stop(activity)
                result.success(true)
            }
            "isIgnoringBatteryOptimizations" -> {
                val pm = activity.getSystemService(PowerManager::class.java)
                result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                        pm.isIgnoringBatteryOptimizations(activity.packageName),
                )
            }
            "requestIgnoreBatteryOptimizations" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    @Suppress("BatteryLife")
                    activity.startActivity(
                        Intent(
                            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            Uri.parse("package:${activity.packageName}"),
                        ),
                    )
                }
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }
}
