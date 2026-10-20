package cn.uuze.botmanager

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.sharedpreferences.SharedPreferencesApi

/**
 * StandardMethodCodec fallback for the generated Pigeon transport. Delegate to
 * the official legacy host, retaining FlutterSharedPreferences, flutter. keys,
 * all historical value encodings and synchronous write results. No data reset.
 */
internal class LegacyPreferencesBridge(private val host: SharedPreferencesApi) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val operations = setOf("getAll", "clear", "remove", "setBool", "setInt", "setDouble", "setString", "setStringList")
        if (call.method !in operations) { result.notImplemented(); return }
        try {
            val value = when (call.method) {
                "getAll", "clear" -> {
                    val prefix = call.argument<String>("prefix") ?: "flutter."
                    require(prefix.startsWith("flutter."))
                    val allowList = call.argument<List<String>>("allowList")
                    if (call.method == "getAll") host.getAll(prefix, allowList)
                    else host.clear(prefix, allowList)
                }
                else -> {
                    val key = requireNotNull(call.argument<String>("key"))
                    require(key.startsWith("flutter."))
                    when (call.method) {
                        "remove" -> host.remove(key)
                        "setBool" -> host.setBool(key, requireNotNull(call.argument<Boolean>("value")))
                        "setInt" -> host.setInt(key, requireNotNull(call.argument<Number>("value")).toLong())
                        "setDouble" -> host.setDouble(key, requireNotNull(call.argument<Number>("value")).toDouble())
                        "setString" -> host.setString(key, requireNotNull(call.argument<String>("value")))
                        else -> host.setEncodedStringList(key, requireNotNull(call.argument<String>("value")))
                    }
                }
            }
            result.success(value)
        } catch (error: Exception) {
            // Never return exception.message, stack traces or stored arguments:
            // a plugin exception can embed a complete config with credentials.
            val causes = setOf("IOException", "SecurityException", "IllegalArgumentException", "ClassCastException", "NumberFormatException", "RuntimeException")
            val cause = error.javaClass.simpleName.takeIf { it in causes } ?: "NativeException"
            result.error(
                if (call.method == "getAll") "PREFERENCES_READ_FAILED" else "PREFERENCES_WRITE_FAILED",
                "Android 偏好设置操作未完成；本地数据未清除。",
                mapOf("cause" to cause, "operation" to call.method)
            )
        }
    }
}
