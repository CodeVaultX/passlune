package app.passlune

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.autofill.Dataset
import android.view.WindowManager
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Opened from the "Fill with Passlune" suggestion. Runs the Dart entry point
 * `autofillMain` (lib/autofill_fill.dart): unlock, pick a login. The pick
 * comes back over the channel and is returned to the system as the dataset
 * that fills the login fields.
 */
@RequiresApi(Build.VERSION_CODES.O)
class AutofillFillActivity : FlutterActivity() {
    companion object {
        const val EXTRA_SITE = "passlune.site"
        const val EXTRA_PACKAGE = "passlune.package"
        const val EXTRA_APP_LABEL = "passlune.appLabel"
        const val EXTRA_USERNAME_ID = "passlune.usernameId"
        const val EXTRA_PASSWORD_ID = "passlune.passwordId"
        /** Browser or other web content: never tie a login to the package. */
        const val EXTRA_NO_TAG = "passlune.noTag"
        /** Installed from Google Play or part of the system. */
        const val EXTRA_TRUSTED_INSTALL = "passlune.trustedInstall"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun getDartEntrypointFunctionName(): String = "autofillMain"

    @Suppress("DEPRECATION")
    private fun id(key: String): AutofillId? = intent.getParcelableExtra(key)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "passlune/autofill_fill").setMethodCallHandler { call, result ->
            when (call.method) {
                "request" -> result.success(
                    mapOf(
                        "site" to (intent.getStringExtra(EXTRA_SITE) ?: ""),
                        "package" to (intent.getStringExtra(EXTRA_PACKAGE) ?: ""),
                        "appLabel" to (intent.getStringExtra(EXTRA_APP_LABEL) ?: ""),
                        "hasUsername" to (id(EXTRA_USERNAME_ID) != null),
                        "hasPassword" to (id(EXTRA_PASSWORD_ID) != null),
                        "noTag" to intent.getBooleanExtra(EXTRA_NO_TAG, true),
                        "trustedInstall" to intent.getBooleanExtra(EXTRA_TRUSTED_INSTALL, false),
                    )
                )
                "pick" -> {
                    val user = call.argument<String>("username") ?: ""
                    val pass = call.argument<String>("password") ?: ""
                    val title = call.argument<String>("title") ?: "Passlune"
                    val presentation = RemoteViews(packageName, R.layout.autofill_item).apply {
                        setTextViewText(R.id.text, if (user.isNotEmpty()) "$title · $user" else title)
                    }
                    val ds = Dataset.Builder(presentation)
                    id(EXTRA_USERNAME_ID)?.let { ds.setValue(it, AutofillValue.forText(user)) }
                    id(EXTRA_PASSWORD_ID)?.let { ds.setValue(it, AutofillValue.forText(pass)) }
                    // For the password page that follows an identifier page —
                    // only when the site (browser) or the app is known for sure.
                    val site = intent.getStringExtra(EXTRA_SITE) ?: ""
                    if (site.isNotEmpty() || !intent.getBooleanExtra(EXTRA_NO_TAG, true)) {
                        RecentPick.remember(
                            intent.getStringExtra(EXTRA_PACKAGE) ?: "",
                            site,
                            RecentPick.Login(title, user, pass),
                        )
                    }
                    setResult(Activity.RESULT_OK, Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, ds.build()))
                    result.success(true)
                    finish()
                }
                "cancel" -> {
                    setResult(Activity.RESULT_CANCELED)
                    result.success(true)
                    finish()
                }
                else -> result.notImplemented()
            }
        }
    }
}
