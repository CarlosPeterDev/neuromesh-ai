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
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileOutputStream
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
                "nativeLibDir" -> result.success(context.applicationInfo.nativeLibraryDir)
                "deviceStatus" -> background(result) { deviceStatus() }
                "decodeAudio" -> background(result) {
                    decodeAudio(call.argument<String>("path")!!, call.argument<Int>("rate") ?: 16000)
                }
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
                "persistedFolders" -> background(result) {
                    context.contentResolver.persistedUriPermissions.map {
                        mapOf("uri" to it.uri.toString(), "read" to it.isReadPermission, "write" to it.isWritePermission)
                    }
                }
                "sharedFileUri" -> background(result) {
                    val file = resolve(call.argument<String>("uri")!!, call.argument<String>("path")!!)
                        ?: throw IllegalArgumentException("File not found")
                    check(file.exists()) { "File does not exist" }
                    file.uri.toString()
                }
                "writeFile" -> background(result) {
                    writeFile(
                        call.argument<String>("uri")!!,
                        call.argument<String>("path") ?: "",
                        call.argument<ByteArray>("bytes") ?: ByteArray(0)
                    )
                }
                "mutateSharedFile" -> background(result) {
                    mutateSharedFile(
                        call.argument<String>("uri")!!,
                        call.argument<String>("path") ?: "",
                        call.argument<String>("action") ?: "",
                        call.argument<String>("name") ?: "",
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
        if (context.contentResolver.persistedUriPermissions.none {
                it.uri == Uri.parse(treeUri) && it.isReadPermission
            }) throw SecurityException("Folder access was revoked. Select it again in Shared Folder.")
        var cur = DocumentFile.fromTreeUri(context, Uri.parse(treeUri)) ?: return null
        val parts = path.split('/').filter { it.isNotEmpty() && it != "." }
        for ((i, part) in parts.withIndex()) {
            if (part == "..") throw IllegalArgumentException("'..' is not allowed")
            var next = cur.findFile(part)
            if (next == null && create) next = cur.createDirectory(part)
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
            val size = f.length()
            val truncated = size > buf.size() || (buf.size() == limit && input.read() != -1)
            return mapOf("bytes" to buf.toByteArray(), "size" to maxOf(size, buf.size().toLong()),
                "truncated" to truncated)
        }
    }

    private fun writeFile(uri: String, path: String, bytes: ByteArray, append: Boolean = false): Boolean {
        requireWriteGrant(uri)
        val clean = mutationPath(path)
        val existing = resolve(uri, path)
        if (existing != null && !existing.isFile) {
            throw IllegalArgumentException("Not a file: $path")
        }
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
        val expected = java.security.MessageDigest.getInstance("SHA-256")
        if (append) context.contentResolver.openInputStream(target.uri).use { input ->
            checkNotNull(input) { "Cannot verify the existing file" }
            val chunk = ByteArray(16384)
            while (true) { val n = input.read(chunk); if (n < 0) break; expected.update(chunk, 0, n) }
        }
        expected.update(bytes)
        val mode = if (append) "wa" else "wt"
        context.contentResolver.openOutputStream(target.uri, mode).use { out ->
            if (out == null) throw IllegalStateException("Cannot write ${target.name}")
            out.write(bytes)
            out.flush()
        }
        val actual = java.security.MessageDigest.getInstance("SHA-256")
        context.contentResolver.openInputStream(target.uri).use { input ->
            checkNotNull(input) { "The written file could not be reopened" }
            val chunk = ByteArray(16384)
            while (true) { val n = input.read(chunk); if (n < 0) break; actual.update(chunk, 0, n) }
        }
        check(target.exists() && expected.digest().contentEquals(actual.digest())) {
            "The provider did not persist the expected file contents. The write may be partial."
        }
        return true
    }

    private fun requireWriteGrant(tree: String) {
        if (context.contentResolver.persistedUriPermissions.none {
                it.uri == Uri.parse(tree) && it.isWritePermission
            }) {
            throw SecurityException("Share this folder with write access in Android's folder picker.")
        }
    }

    private fun mutationPath(path: String): List<String> = path.split('/').also { parts ->
        require(parts.all { part ->
            part.isNotBlank() && part != "." && part != ".." &&
                part.none { it == '\\' || it == ':' || it.isISOControl() }
        }) { "Use a relative path inside the shared folder." }
    }

    private fun mutateSharedFile(
        uri: String, path: String, action: String, name: String, bytes: ByteArray
    ): String {
        requireWriteGrant(uri)
        val parts = mutationPath(path)
        if (action == "append") {
            writeFile(uri, path, bytes, append = true)
            return path
        }
        val parentPath = parts.dropLast(1).joinToString("/")
        val parent = resolve(uri, parentPath)
            ?: throw IllegalArgumentException("Parent folder not found: $parentPath")
        require(parent.isDirectory) { "The parent is not a folder." }
        val existing = parent.findFile(parts.last())
        if (action == "mkdir") {
            require(existing == null) { "That folder or file already exists." }
            val created = parent.createDirectory(parts.last())
                ?: throw IllegalStateException("The provider could not create the folder.")
            check(created.exists() && created.isDirectory) { "Folder creation could not be verified" }
            return parts.dropLast(1).plus(created.name ?: parts.last()).joinToString("/")
        }
        require(existing?.isFile == true) { "No file found at $path." }
        val file = checkNotNull(existing)
        return when (action) {
            "delete" -> {
                check(file.delete()) { "The provider could not delete the file." }
                path
            }
            "rename" -> {
                require(mutationPath(name).size == 1) { "Give only the new file name." }
                require(parent.findFile(name) == null) { "That name is already in use." }
                check(file.renameTo(name)) { "The provider could not rename the file." }
                file.name ?: name
            }
            else -> throw IllegalArgumentException("Unknown shared-file action")
        }
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
