package com.neuromesh.ai

import android.app.ActivityManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Environment
import android.os.StatFs
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.FileOutputStream
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Battery, thermal and "share to NeuroMesh" plumbing for the Dart side. */
class DeviceBridge(private val context: Context) {
    private var channel: MethodChannel? = null
    private var pendingShare: String? = null
    private var pendingNewChat = false
    private val main = Handler(Looper.getMainLooper())


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
                "deviceStatus" -> background(result) { deviceStatus() }
                "decodeAudio" -> background(result) {
                    decodeAudio(call.argument<String>("path")!!, call.argument<Int>("rate") ?: 16000)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Decodes any audio/video file to raw 16-bit mono PCM at [rate] Hz; returns the temp file path. */
    private fun decodeAudio(path: String, rate: Int): String {
        val ex = MediaExtractor()
        ex.setDataSource(path)
        var track = -1
        var fmt: MediaFormat? = null
        for (i in 0 until ex.trackCount) {
            val f = ex.getTrackFormat(i)
            if ((f.getString(MediaFormat.KEY_MIME) ?: "").startsWith("audio/")) { track = i; fmt = f; break }
        }
        if (track < 0 || fmt == null) { ex.release(); throw Exception("No audio track in this file") }
        ex.selectTrack(track)
        val codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(fmt, null, null, 0)
        codec.start()
        var srcRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val out = File(context.cacheDir, "decoded_${System.nanoTime()}.pcm")
        val fos = FileOutputStream(out)
        val info = MediaCodec.BufferInfo()
        var inDone = false
        var outDone = false
        var pos = 0.0
        val step = srcRate.toDouble() / rate
        var prev = 0
        var have = false
        val buf = java.io.ByteArrayOutputStream()
        while (!outDone) {
            if (!inDone) {
                val ii = codec.dequeueInputBuffer(10000)
                if (ii >= 0) {
                    val b = codec.getInputBuffer(ii)!!
                    val n = ex.readSampleData(b, 0)
                    if (n < 0) {
                        codec.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inDone = true
                    } else {
                        codec.queueInputBuffer(ii, 0, n, ex.sampleTime, 0)
                        ex.advance()
                    }
                }
            }
            val oi = codec.dequeueOutputBuffer(info, 10000)
            if (oi >= 0) {
                val ob = codec.getOutputBuffer(oi)!!
                ob.position(info.offset); ob.limit(info.offset + info.size)
                val sb = ob.order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                val total = sb.remaining()
                var idx = 0
                buf.reset()
                while (idx + channels <= total) {
                    var sum = 0
                    for (c in 0 until channels) sum += sb.get(idx + c).toInt()
                    val mono = sum / channels
                    // linear resample to `rate`
                    pos += 1.0
                    while (pos >= step) {
                        val frac = if (have) (1.0 - (pos - step)).coerceIn(0.0, 1.0) else 1.0
                        val v = if (have) (prev + (mono - prev) * frac).toInt() else mono
                        buf.write(v and 0xFF); buf.write((v shr 8) and 0xFF)
                        pos -= step
                    }
                    prev = mono; have = true
                    idx += channels
                }
                fos.write(buf.toByteArray())
                codec.releaseOutputBuffer(oi, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outDone = true
            } else if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val nf = codec.outputFormat
                srcRate = nf.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                channels = nf.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            }
        }
        fos.close(); codec.stop(); codec.release(); ex.release()
        return out.absolutePath
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                val out = work()
                main.post { result.success(out) }
            } catch (e: Exception) {
                main.post { result.error("FILES", e.message ?: e.javaClass.simpleName, null) }
            }
        }.start()
    }

    private fun thermalStatus(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.currentThermalStatus
    }

    /** Read-only phone facts the AI may ask for. Needs no dangerous permission. */
    private fun deviceStatus(): Map<String, Any> {
        val out = HashMap<String, Any>(batteryInfo())
        out["thermal"] = thermalStatus()
        try {
            val st = StatFs(Environment.getDataDirectory().path)
            out["storageFree"] = st.availableBytes
            out["storageTotal"] = st.totalBytes
        } catch (_: Exception) {
        }
        try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            out["ramTotal"] = mi.totalMem
            out["ramFree"] = mi.availMem
            out["lowMemory"] = mi.lowMemory
            out["ramLowThreshold"] = mi.threshold
        } catch (_: Exception) {
        }
        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val caps = cm.getNetworkCapabilities(cm.activeNetwork)
            out["network"] = when {
                caps == null -> "offline"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                else -> "other"
            }
            out["metered"] = cm.isActiveNetworkMetered
        } catch (_: Exception) {
        }
        out["model"] = Build.MODEL ?: ""
        out["android"] = Build.VERSION.RELEASE ?: ""
        out["cores"] = Runtime.getRuntime().availableProcessors()
        return out
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
