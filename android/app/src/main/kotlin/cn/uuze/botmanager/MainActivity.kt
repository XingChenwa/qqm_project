package cn.uuze.botmanager

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.uuze.botmanager/updates")
            .setMethodCallHandler { call, result ->
                if (call.method == "deviceInfo") {
                    // Public model/OS data only: no Android ID, IMEI, serial or accounts.
                    val model = listOf(Build.MANUFACTURER, Build.MODEL).joinToString(" ").trim()
                    result.success(mapOf(
                        "device_name" to Build.MODEL,
                        "device_model" to model,
                        "system_version" to "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
                        "system_arch" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown")
                    ))
                    return@setMethodCallHandler
                }
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
