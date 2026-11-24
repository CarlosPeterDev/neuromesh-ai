package com.neuromesh.ai

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/** Keeps the app's active work visible and routes Stop back to its owner. */
class BackgroundWorkService : Service() {
    companion object {
        private const val CHANNEL = "neuromesh_background_work"
        private const val NOTIFICATION = 4202
        private const val STOP = "com.neuromesh.ai.STOP_BACKGROUND_WORK"
        private val work = linkedMapOf<String, String>()
        private var running: BackgroundWorkService? = null
        private var appContext: Context? = null
        var onStopRequested: ((String) -> Unit)? = null

        fun begin(context: Context, id: String, kind: String) {
            require(kind == "image" || kind == "relay")
            appContext = context.applicationContext
            createChannel(context)
            val start = work.isEmpty() || running == null
            work[id] = kind
            try {
                if (start) {
                    ContextCompat.startForegroundService(context,
                        Intent(context, BackgroundWorkService::class.java))
                } else {
                    running?.updateNotification()
                }
            } catch (_: IllegalStateException) {
                // Android can deny a foreground start after the activity is hidden.
                notificationManager(context).notify(NOTIFICATION, notification(context))
            } catch (error: RuntimeException) {
                work.remove(id)
                throw error
            }
        }

        fun finish(id: String) {
            if (work.remove(id) == null) return
            val service = running
            if (service != null) {
                service.updateNotification()
            } else {
                appContext?.let { context ->
                    val manager = notificationManager(context)
                    if (work.isEmpty()) manager.cancel(NOTIFICATION)
                    else manager.notify(NOTIFICATION, notification(context))
                }
            }
        }

        private fun notificationManager(context: Context): NotificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        private fun createChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                notificationManager(context).createNotificationChannel(
                    NotificationChannel(CHANNEL, "Background work", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }

        private fun notification(context: Context): Notification {
            val title = when (work.values.singleOrNull()) {
                "image" -> "Image generation running"
                "relay" -> "Remote access is on"
                else -> "NeuroMesh background work"
            }
            val builder = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_tile)
                .setContentTitle(title)
                .setContentText("Use Stop to cancel the active work.")
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
                builder.setContentIntent(PendingIntent.getActivity(context, 0, launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            }
            for ((id, kind) in work) {
                val cancel = Intent(context, BackgroundWorkService::class.java)
                    .setAction(STOP)
                    .setData(Uri.Builder().scheme("neuromesh").authority("background-work")
                        .appendPath(id).build())
                val pending = PendingIntent.getService(context, 0, cancel, PendingIntent.FLAG_IMMUTABLE)
                val label = when {
                    work.size == 1 -> "Stop"
                    kind == "image" -> "Stop image generation"
                    else -> "Stop remote access"
                }
                builder.addAction(0, label, pending)
            }
            return builder.build()
        }
    }

    private var foreground = false
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        running = this
        createChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = if (intent?.action == STOP) intent.data?.lastPathSegment else null
        if (id != null && work.remove(id) != null) onStopRequested?.invoke(id)
        if (id == null && !foreground && work.isEmpty()) promote(notification(this))
        updateNotification()
        return START_NOT_STICKY
    }

    private fun updateNotification() {
        if (work.isNotEmpty()) {
            promote(notification(this))
            keepAwake()
        } else {
            stopForeground(STOP_FOREGROUND_REMOVE)
            notificationManager(this).cancel(NOTIFICATION)
            foreground = false
            stopSelf()
        }
    }

    @SuppressLint("WakelockTimeout") // Released when Android destroys the foreground service.
    private fun keepAwake() {
        if (wakeLock != null) return
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "NeuroMesh:BackgroundWork")
        wakeLock?.acquire()
    }

    private fun promote(notification: Notification) {
        ServiceCompat.startForeground(this, NOTIFICATION, notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        foreground = true
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        val ids = work.keys.toList()
        work.clear()
        for (id in ids) onStopRequested?.invoke(id)
        updateNotification()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        if (running === this) running = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }
}
