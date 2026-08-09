package com.dhivalabs.home_deck

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service that keeps HomeDeck's process — and therefore the
 * Dart-side wake-word engine and its microphone stream — alive while the
 * app is backgrounded or the screen is locked.
 *
 * It owns no audio itself: the mic pipeline lives in Dart. Android just
 * requires a visible foreground service with the `microphone` type for an
 * app to keep recording when not on screen, which is exactly what "hey
 * assistant with the phone in my pocket" needs. The persistent
 * notification is the OS-mandated tradeoff (Google's and Amazon's own
 * apps show one too).
 */
class WakeWordService : Service() {

    companion object {
        private const val CHANNEL_ID = "homedeck_assistant"
        private const val NOTIFICATION_ID = 7301

        fun start(context: Context) {
            val intent = Intent(context, WakeWordService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, WakeWordService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // If the OS kills us under pressure, come back — the Dart engine
        // re-arms when the process restarts and the app resumes.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Voice assistant",
                // MIN keeps it out of the status bar icon row on most OEMs.
                NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description = "Shown while HomeDeck listens for the wake word"
                setShowBadge(false)
            },
        )
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Listening for your wake word")
            .setContentText("HomeDeck voice assistant is on")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }
}
