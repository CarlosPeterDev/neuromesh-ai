package com.neuromesh.ai

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Battery, thermal and "share to NeuroMesh" plumbing for the Dart side. */
class DeviceBridge(private val context: Context) {
    private var channel: MethodChannel? = null
    private var pendingShare: String? = null
    private var pendingNewChat = false

    fun register(engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "com.neuromesh.ai/device")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "thermalStatus" -> result.success(thermalStatus())
                "batteryInfo" -> result.success(batteryInfo())
                "takeNewChat" -> {
                    result.success(pendingNewChat)
                    pendingNewChat = false
                }
                "takeSharedText" -> {
                    result.success(pendingShare)
                    pendingShare = null
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun thermalStatus(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.currentThermalStatus
    }

    private fun batteryInfo(): Map<String, Any> {
        val i = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = i?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = i?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val status = i?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "level" to (if (level >= 0 && scale > 0) level * 100 / scale else -1),
            "charging" to charging,
            "saver" to pm.isPowerSaveMode
        )
    }

    /** Call from onCreate and onNewIntent. */
    fun handleIntent(intent: Intent?) {
        if (intent?.getBooleanExtra("new_chat", false) == true) {
            intent.removeExtra("new_chat")
            pendingNewChat = true
            channel?.invokeMethod("sharedTextReady", null)
        }
        if (intent?.action == Intent.ACTION_SEND && intent.type?.startsWith("text/") == true) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
            pendingShare = text
            // Ping Dart; it pulls the text with takeSharedText (also covers cold start).
            channel?.invokeMethod("sharedTextReady", null)
        }
    }
}
