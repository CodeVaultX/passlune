package app.passlune

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.PersistableBundle
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import android.view.autofill.AutofillManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Block screenshots and hide content in the recent-apps switcher.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "passlune/autofill").setMethodCallHandler { call, result ->
            val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
            when (call.method) {
                "status" -> {
                    // supported: Android 8+; enabled: Passlune is the chosen autofill service.
                    val enabled = supported && getSystemService(AutofillManager::class.java)?.hasEnabledAutofillServices() == true
                    result.success(mapOf("supported" to supported, "enabled" to enabled, "pending" to PendingStore.count(this)))
                }
                "openSettings" -> {
                    if (!supported) return@setMethodCallHandler result.success(false)
                    try {
                        startActivity(Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE).setData(Uri.parse("package:$packageName")))
                        result.success(true)
                    } catch (_: Exception) {
                        // Some ROMs lack the direct screen: fall back to the general settings list.
                        try {
                            startActivity(Intent(Settings.ACTION_SETTINGS))
                        } catch (_: Exception) {
                        }
                        result.success(false)
                    }
                }
                "takePending" -> result.success(PendingStore.peekAll(this))
                "dropPending" -> {
                    PendingStore.drop(this, call.argument<Int>("count") ?: 0)
                    result.success(true)
                }
                // Copying a password: marked sensitive so Android 13+ doesn't
                // show it in the clipboard preview.
                "copySecret" -> {
                    val cm = getSystemService(ClipboardManager::class.java)
                    val clip = ClipData.newPlainText("Passlune", call.argument<String>("text") ?: "")
                    if (Build.VERSION.SDK_INT >= 24) {
                        clip.description.extras = PersistableBundle().apply {
                            putBoolean("android.content.extra.IS_SENSITIVE", true)
                        }
                    }
                    cm?.setPrimaryClip(clip)
                    result.success(true)
                }
                // Clears without reading first: a backgrounded app can't read
                // the clipboard on Android 10+, so read-then-clear never cleared.
                "forgetRecentPick" -> {
                    RecentPick.clear()
                    result.success(true)
                }
                "clearClipboard" -> {
                    val cm = getSystemService(ClipboardManager::class.java)
                    if (Build.VERSION.SDK_INT >= 28) cm?.clearPrimaryClip()
                    else cm?.setPrimaryClip(ClipData.newPlainText("", ""))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
