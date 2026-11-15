package com.neuromesh.ai

import android.app.Activity
import android.app.ActivityManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Environment
import android.os.StatFs
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Battery, thermal and "share to NeuroMesh" plumbing for the Dart side. */
class DeviceBridge(private val context: Context) {
    private var channel: MethodChannel? = null
    private var pendingShare: String? = null
    private var pendingNewChat = false
    private var pendingPick: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    companion object {
        const val TREE_REQUEST = 7311
        private const val MAX_READ = 4 * 1024 * 1024
    }

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
                "pickFolder" -> pickFolder(result)
                "listFolder" -> background(result) {
                    listFolder(call.argument<String>("uri")!!, call.argument<String>("path") ?: "")
                }
                "readFile" -> background(result) {
                    readFile(
                        call.argument<String>("uri")!!,
                        call.argument<String>("path") ?: "",
                        call.argument<Int>("maxBytes") ?: MAX_READ
                    )
                }
                "writeFile" -> background(result) {
                    writeFile(
                        call.argument<String>("uri")!!,
                        call.argument<String>("path") ?: "",
                        call.argument<ByteArray>("bytes") ?: ByteArray(0)
                    )
                }
                "releaseFolder" -> background(result) {
                    try {
                        context.contentResolver.releasePersistableUriPermission(
                            Uri.parse(call.argument<String>("uri")!!),
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        )
                    } catch (_: Exception) {
                    }
                    true
                }
                else -> result.notImplemented()
            }
        }
    }

    // ── Folder access (Storage Access Framework) ────────────────────────
    // The user picks a folder in Android's own picker; the app only ever sees
    // what is inside it. No broad storage permission is requested.

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

    private fun pickFolder(result: MethodChannel.Result) {
        val activity = context as? Activity
        if (activity == null) {
            result.error("NO_ACTIVITY", "No screen available", null)
            return
        }
        pendingPick?.success(null)
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }
        activity.startActivityForResult(intent, TREE_REQUEST)
    }

    /** Returns true when the result belonged to the folder picker. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != TREE_REQUEST) return false
        val cb = pendingPick
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            cb?.success(null)
            return true
        }
        try {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (_: Exception) {
            try {
                context.contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {
            }
        }
        val name = DocumentFile.fromTreeUri(context, uri)?.name ?: "Folder"
        cb?.success(mapOf("uri" to uri.toString(), "name" to name))
        return true
    }

    private fun resolve(treeUri: String, path: String, create: Boolean = false): DocumentFile? {
        var cur = DocumentFile.fromTreeUri(context, Uri.parse(treeUri)) ?: return null
        val parts = path.split('/').filter { it.isNotEmpty() && it != "." }
        for ((i, part) in parts.withIndex()) {
            if (part == "..") throw IllegalArgumentException("'..' is not allowed")
            var next = cur.findFile(part)
            if (next == null && create && i < parts.size - 1) next = cur.createDirectory(part)
            cur = next ?: return null
        }
        return cur
    }

    private fun listFolder(uri: String, path: String): List<Map<String, Any>> {
        val dir = resolve(uri, path) ?: throw IllegalArgumentException("Folder not found: $path")
        if (!dir.isDirectory) throw IllegalArgumentException("Not a folder: $path")
        return dir.listFiles().take(500).map {
            mapOf(
                "name" to (it.name ?: "?"),
                "isDir" to it.isDirectory,
                "size" to it.length(),
                "modified" to it.lastModified()
            )
        }.sortedWith(compareBy({ !(it["isDir"] as Boolean) }, { (it["name"] as String).lowercase() }))
    }

    private fun readFile(uri: String, path: String, maxBytes: Int): Map<String, Any> {
        val f = resolve(uri, path) ?: throw IllegalArgumentException("File not found: $path")
        if (!f.isFile) throw IllegalArgumentException("Not a file: $path")
        val limit = maxBytes.coerceIn(1, MAX_READ)
        context.contentResolver.openInputStream(f.uri).use { input ->
            if (input == null) throw IllegalStateException("Cannot open $path")
            val buf = java.io.ByteArrayOutputStream()
            val chunk = ByteArray(16 * 1024)
            while (buf.size() < limit) {
                val n = input.read(chunk, 0, minOf(chunk.size, limit - buf.size()))
                if (n <= 0) break
                buf.write(chunk, 0, n)
            }
            return mapOf("bytes" to buf.toByteArray(), "size" to f.length(), "truncated" to (f.length() > buf.size()))
        }
    }

    private fun writeFile(uri: String, path: String, bytes: ByteArray): Boolean {
        val clean = path.split('/').filter { it.isNotEmpty() }
        if (clean.isEmpty()) throw IllegalArgumentException("Give a file path")
        val existing = resolve(uri, path, create = true)
        val target = if (existing != null && existing.isFile) {
            existing
        } else {
            val parent = resolve(uri, clean.dropLast(1).joinToString("/"), create = true)
                ?: throw IllegalArgumentException("Folder not found")
            val name = clean.last()
            val ext = name.substringAfterLast('.', "").lowercase()
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
            parent.createFile(mime, name) ?: throw IllegalStateException("Could not create $name")
        }
        context.contentResolver.openOutputStream(target.uri, "wt").use { out ->
            if (out == null) throw IllegalStateException("Cannot write ${target.name}")
            out.write(bytes)
        }
        return true
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
