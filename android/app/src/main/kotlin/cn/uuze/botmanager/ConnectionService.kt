package cn.uuze.botmanager

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/** Explicit, visible keep-alive for the existing Flutter gateway. No second
 * engine, bot credentials, boot receiver, hidden audio or self-restart loop. */
class ConnectionService : Service() {
    companion object {
        @Volatile
        var running = false
            private set
    }
    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private val renew = object : Runnable {
        override fun run() {
            val lock = wakeLock ?: return
            if (lock.isHeld) lock.release()
            lock.acquire(10 * 60 * 1000L)
            handler.postDelayed(this, 8 * 60 * 1000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel("qqm_connection", "机器人后台连接", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "仅在用户启用后台连接并运行机器人时显示"
                    setShowBadge(false)
                }
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val pending = PendingIntent.getActivity(this, 23337,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(this, "qqm_connection")
            .setSmallIcon(R.drawable.ic_stat_qqm)
            .setContentTitle("QQ机器人管理器 · 后台连接")
            .setContentText("正在保持机器人连接，点击返回应用；可在设置中关闭")
            .setOngoing(true).setSilent(true).setContentIntent(pending)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).build()
        try {
            ServiceCompat.startForeground(this, 23337, notification,
                if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING else 0)
            running = true
            if (wakeLock == null) {
                wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "qqm:gateway").apply { setReferenceCounted(false) }
                renew.run()
            }
        } catch (_: Exception) {
            stopSelf()
        }
        // The user must reopen the app after a force stop/explicit dismissal.
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) { stopSelf() }
    override fun onDestroy() {
        running = false
        handler.removeCallbacksAndMessages(null)
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
