package com.sergio.lector_docs

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Servicio en primer plano mientras la app lee en voz alta: muestra una
 * notificación con Pausar/Detener y mantiene viva la app para que la
 * lectura siga con la pantalla apagada.
 */
class ReadAloudService : Service() {

    companion object {
        private const val CHANNEL_ID = "lectura_en_voz_alta"
        private const val NOTIFICATION_ID = 4107
        private const val ACTION_TOGGLE = "com.sergio.lector_docs.action.TOGGLE"
        private const val ACTION_STOP = "com.sergio.lector_docs.action.STOP"

        private var instance: ReadAloudService? = null
        private var lastTitle = "Lector"

        fun start(context: Context, title: String) {
            lastTitle = title
            val running = instance
            if (running != null && running.isForeground) {
                running.setPlaying(title, true)
                return
            }
            val intent = Intent(context, ReadAloudService::class.java).putExtra("title", title)
            try {
                if (Build.VERSION.SDK_INT >= 26) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Si Android no deja iniciarlo, la lectura sigue con la app abierta.
            }
        }

        fun update(context: Context, title: String, playing: Boolean) {
            lastTitle = title
            instance?.setPlaying(title, playing)
        }

        fun stop(context: Context) {
            if (instance != null) {
                context.stopService(Intent(context, ReadAloudService::class.java))
            }
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= 26) {
                val manager =
                    context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                    val channel = NotificationChannel(
                        CHANNEL_ID,
                        "Lectura en voz alta",
                        NotificationManager.IMPORTANCE_LOW
                    )
                    channel.description = "Controles mientras el lector te lee"
                    channel.setShowBadge(false)
                    manager.createNotificationChannel(channel)
                }
            }
        }

        @Suppress("DEPRECATION")
        private fun buildNotification(context: Context, title: String, playing: Boolean): Notification {
            ensureChannel(context)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val openApp = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                flags
            )
            val toggle = PendingIntent.getService(
                context, 1,
                Intent(context, ReadAloudService::class.java).setAction(ACTION_TOGGLE),
                flags
            )
            val stop = PendingIntent.getService(
                context, 2,
                Intent(context, ReadAloudService::class.java).setAction(ACTION_STOP),
                flags
            )
            val builder = if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                Notification.Builder(context)
            }
            builder
                .setSmallIcon(
                    if (playing) android.R.drawable.ic_media_play
                    else android.R.drawable.ic_media_pause
                )
                .setContentTitle(title)
                .setContentText(if (playing) "Leyendo en voz alta" else "En pausa")
                .setContentIntent(openApp)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(
                    Notification.Action.Builder(
                        Icon.createWithResource(
                            context,
                            if (playing) android.R.drawable.ic_media_pause
                            else android.R.drawable.ic_media_play
                        ),
                        if (playing) "Pausar" else "Seguir",
                        toggle
                    ).build()
                )
                .addAction(
                    Notification.Action.Builder(
                        Icon.createWithResource(context, android.R.drawable.ic_menu_close_clear_cancel),
                        "Detener",
                        stop
                    ).build()
                )
            if (Build.VERSION.SDK_INT >= 31) {
                builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
            return builder.build()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var isForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TOGGLE -> {
                MainActivity.sendToDart("ttsToggle")
                if (!isForeground) stopSelf()
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                MainActivity.sendToDart("ttsStop")
                stopSelf()
                return START_NOT_STICKY
            }
        }
        val title = intent?.getStringExtra("title") ?: lastTitle
        val notification = buildNotification(this, title, true)
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        isForeground = true
        acquireWakeLock()
        return START_NOT_STICKY
    }

    fun setPlaying(title: String, playing: Boolean) {
        if (!isForeground) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(this, title, playing))
        if (playing) acquireWakeLock() else releaseWakeLock()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Lector:LecturaEnVozAlta")
        lock.setReferenceCounted(false)
        lock.acquire(4 * 60 * 60 * 1000L)
        wakeLock = lock
    }

    private fun releaseWakeLock() {
        val lock = wakeLock
        if (lock != null && lock.isHeld) lock.release()
        wakeLock = null
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Si cierras la app desde "Recientes", se detiene la lectura.
        MainActivity.sendToDart("ttsStop")
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseWakeLock()
        isForeground = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (instance === this) instance = null
        super.onDestroy()
    }
}
