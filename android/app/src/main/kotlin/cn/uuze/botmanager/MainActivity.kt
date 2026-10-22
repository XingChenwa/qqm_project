package cn.uuze.botmanager

import android.content.Intent
import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.flutter.plugins.sharedpreferences.LegacySharedPreferencesPlugin
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private var notificationChannel: MethodChannel? = null
    private var permissionReply: MethodChannel.Result? = null
    private var notificationLaunch: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.uuze.botmanager/background")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            require(NotificationManagerCompat.from(this).areNotificationsEnabled())
                            val service = Intent(this, ConnectionService::class.java)
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
                            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                                if (ConnectionService.running) result.success(null)
                                else result.error("BACKGROUND_FAILED", "后台服务未能启动，请检查通知权限及电池限制", null)
                            }, 300)
                        }
                        "stop" -> { stopService(Intent(this, ConnectionService::class.java)); result.success(null) }
                        "batterySettings" -> {
                            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                            result.success(null)
                        }
                        "openSettings" -> {
                            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) { result.error("BACKGROUND_FAILED", "请检查通知权限及电池限制后重试", null) }
            }
        notificationLaunch = intent?.getStringExtra("qqm_notification")
        notificationChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.uuze.botmanager/notifications").also { channel ->
            channel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "isAllowed" -> result.success(NotificationManagerCompat.from(this).areNotificationsEnabled())
                        "consumeLaunch" -> { result.success(notificationLaunch); notificationLaunch = null; intent?.removeExtra("qqm_notification") }
                        "requestPermission" -> {
                            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                if (permissionReply != null) { result.error("NOTIFICATION_BUSY", "正在申请通知权限", null) }
                                else { permissionReply = result; requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 23336) }
                            } else result.success(NotificationManagerCompat.from(this).areNotificationsEnabled())
                        }
                        "openSettings" -> {
                            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                            result.success(null)
                        }
                        "cancelAll" -> {
                            // Do not cancel the optional foreground-service notice.
                            val manager = getSystemService(NotificationManager::class.java)
                            manager.activeNotifications.filter {
                                if (Build.VERSION.SDK_INT >= 26) it.notification.channelId == "qqm_messages" else it.id != 23337
                            }
                                .forEach { manager.cancel(it.id) }
                            result.success(null)
                        }
                        "show" -> {
                            val notifications = NotificationManagerCompat.from(this)
                            if (!notifications.areNotificationsEnabled()) { result.success(null); return@setMethodCallHandler }
                            if (Build.VERSION.SDK_INT >= 26) {
                                getSystemService(NotificationManager::class.java)?.createNotificationChannel(
                                    NotificationChannel("qqm_messages", "聊天与群事件", NotificationManager.IMPORTANCE_DEFAULT).apply {
                                        description = "QQ机器人管理器在线收到的消息、入群申请和群成员事件"
                                    })
                            }
                            val id = call.argument<Number>("id")?.toInt() ?: error("缺少通知编号")
                            val payload = call.argument<String>("payload") ?: error("缺少会话信息")
                            require(payload.length <= 8192)
                            val target = Intent(this, MainActivity::class.java).apply {
                                putExtra("qqm_notification", payload)
                                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                            }
                            val pending = PendingIntent.getActivity(this, id, target, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                            val body = call.argument<String>("body")?.take(1000) ?: ""
                            val notification = NotificationCompat.Builder(this, "qqm_messages")
                                .setSmallIcon(R.drawable.ic_stat_qqm)
                                .setContentTitle(call.argument<String>("title")?.take(200) ?: "QQ机器人管理器")
                                .setContentText(body).setStyle(NotificationCompat.BigTextStyle().bigText(body))
                                .setContentIntent(pending).setAutoCancel(true).setOnlyAlertOnce(true)
                                .setCategory(NotificationCompat.CATEGORY_MESSAGE).setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                                .setGroup(call.argument<String>("thread")).build()
                            if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                                notifications.notify(id, notification)
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) { result.error("NOTIFICATION_FAILED", "系统通知操作未完成，请检查通知权限", null) }
            }
        }
        // Keep a stable host for both transports. Re-registering Pigeon alone
        // cannot repair every ROM/channel failure; the standard channel calls
        // the same host directly, without touching or copying the preference file.
        val preferencesHost = (flutterEngine.plugins.get(LegacySharedPreferencesPlugin::class.java)
            as? LegacySharedPreferencesPlugin) ?: LegacySharedPreferencesPlugin().also {
            flutterEngine.plugins.add(it)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "cn.uuze.botmanager/preferences",
            StandardMethodCodec.INSTANCE,
            flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue()
        ).setMethodCallHandler(LegacyPreferencesBridge(preferencesHost))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.uuze.botmanager/updates")
            .setMethodCallHandler { call, result ->
                if (call.method != "installApk") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val supplied = call.argument<String>("path") ?: error("缺少安装包路径")
                    val file = File(supplied).canonicalFile
                    val allowed = File(filesDir, "updates").canonicalFile.path + File.separator
                    require(file.path.startsWith(allowed) && file.isFile && file.extension == "apk") {
                        "只能安装本应用已经校验的更新缓存"
                    }
                    @Suppress("DEPRECATION")
                    val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
                    @Suppress("DEPRECATION")
                    val archive = packageManager.getPackageArchiveInfo(file.path, flags)
                        ?: error("无法读取 APK，请重新下载")
                    @Suppress("DEPRECATION")
                    val installed = packageManager.getPackageInfo(packageName, flags)
                    require(archive.packageName == packageName) { "APK 包名与当前应用不同，已阻止安装" }
                    val newVersion = version(archive)
                    val advertised = call.argument<Number>("build")?.toLong()
                    require(newVersion > version(installed) && newVersion == advertised) {
                        "APK 构建号与发布信息不符，或版本不高于当前应用"
                    }
                    require(certificates(archive).isNotEmpty() && certificates(archive) == certificates(installed)) {
                        "APK 签名与当前版本不同，不能覆盖升级。请联系发布者使用固定签名；不会自动卸载旧版或清除数据。"
                    }
                    if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")))
                        result.error("INSTALL_PERMISSION", "请在系统中允许本应用安装更新，返回后再次点击安装。", null)
                        return@setMethodCallHandler
                    }
                    val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                    startActivity(Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    })
                    result.success(null)
                } catch (exception: Exception) {
                    result.error("INSTALL_FAILED", exception.message ?: "系统未能打开安装界面", null)
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra("qqm_notification")?.let { payload ->
            notificationLaunch = payload
            notificationChannel?.invokeMethod("opened", payload)
            intent.removeExtra("qqm_notification")
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 23336) {
            permissionReply?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED && NotificationManagerCompat.from(this).areNotificationsEnabled())
            permissionReply = null
        }
    }

    override fun onDestroy() {
        if (!isChangingConfigurations) stopService(Intent(this, ConnectionService::class.java))
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun certificates(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signatures?.map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { "%02x".format(it.toInt() and 255) }
        }?.toSet() ?: emptySet()
    }
}
