package app.passlune

import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveInfo
import android.service.autofill.SaveRequest
import android.text.InputType
import android.view.View
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import android.widget.Toast
import androidx.annotation.RequiresApi
import org.json.JSONObject

/**
 * "Save to Passlune?" for logins typed in other apps and in browsers (Chrome
 * with "Autofill using another service", Firefox, Samsung Internet, ...).
 *
 * Fill requests get a "Fill with Passlune" suggestion plus a SaveInfo. Two-step logins (e-mail on one screen, password on the
 * next) use FLAG_DELAY_SAVE so the save request carries both screens.
 */
@RequiresApi(Build.VERSION_CODES.O)
class PassluneAutofillService : AutofillService() {

    companion object {
        /**
         * Browsers whose reported web domain is trusted. Any other app can put
         * any domain into its view structure (or a WebView), so for those only
         * the package name is used — otherwise an app could pose as paypal.com
         * and be offered the PayPal login.
         */
        val BROWSERS = setOf(
            "com.android.chrome", "com.chrome.beta", "com.chrome.dev", "com.chrome.canary",
            "org.mozilla.firefox", "org.mozilla.firefox_beta", "org.mozilla.fenix", "org.mozilla.focus",
            "com.microsoft.emmx", "com.sec.android.app.sbrowser", "com.sec.android.app.sbrowser.beta",
            "com.opera.browser", "com.opera.browser.beta", "com.opera.mini.native", "com.brave.browser",
            "com.vivaldi.browser", "com.duckduckgo.mobile.android", "com.yandex.browser",
            "com.kiwibrowser.browser", "org.chromium.chrome",
        )
    }

    private class Fields {
        var username: AutofillId? = null
        var password: AutofillId? = null
        var usernameValue: String? = null
        var passwordValue: String? = null
        var webDomain: String? = null
        var usernameDomain: String? = null
        var passwordDomain: String? = null
        var anyWeb = false // some view on screen carries a web domain
        var usernameStrong = false // marked as username/e-mail, not just "phone" etc.
        // Value to save: on a change-password form (current / new / confirm)
        // the new password, not the first field's.
        var savePasswordValue: String? = null
        val passwords = mutableListOf<Pair<String?, Boolean>>() // value, looks like a new password
        val textFields = mutableListOf<Pair<AutofillId, String?>>() // in screen order
    }

    override fun onFillRequest(request: FillRequest, cancel: CancellationSignal, callback: FillCallback) {
        val structure = request.fillContexts.lastOrNull()?.structure ?: return callback.onSuccess(null)
        if (structure.activityComponent.packageName == packageName) return callback.onSuccess(null)
        val f = parse(structure)
        val ids = listOfNotNull(f.username, f.password)
        if (ids.isEmpty()) return callback.onSuccess(null)
        var type = 0
        if (f.username != null) type = type or SaveInfo.SAVE_DATA_TYPE_USERNAME
        if (f.password != null) type = type or SaveInfo.SAVE_DATA_TYPE_PASSWORD
        val save = SaveInfo.Builder(type, ids.toTypedArray())
        var flags = SaveInfo.FLAG_SAVE_ON_ALL_VIEWS_INVISIBLE
        // Identifier screen of a two-step login: keep it for the next screen.
        if (f.password == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) flags = flags or SaveInfo.FLAG_DELAY_SAVE
        save.setFlags(flags)

        // "Fill with Passlune": the vault is encrypted, so the suggestion is an
        // authentication dataset. Tapping it opens AutofillFillActivity, which
        // unlocks the vault, lets the user pick a login and returns the
        // filled dataset.
        val pkg = structure.activityComponent.packageName
        val browser = pkg in BROWSERS
        val site = if (browser) f.webDomain?.removePrefix("www.") ?: "" else ""
        // Web content in an app that isn't a known browser (a WebView app, an
        // unlisted browser), or a browser page whose site is unknown: never
        // tie a login to the package and never offer a recent pick there.
        val noTag = browser || f.anyWeb
        val intent = Intent(this, AutofillFillActivity::class.java)
            .putExtra(AutofillFillActivity.EXTRA_SITE, site)
            .putExtra(AutofillFillActivity.EXTRA_PACKAGE, pkg)
            .putExtra(AutofillFillActivity.EXTRA_APP_LABEL, appLabel(pkg))
            .putExtra(AutofillFillActivity.EXTRA_NO_TAG, noTag)
            .putExtra(AutofillFillActivity.EXTRA_TRUSTED_INSTALL, !noTag && fromTrustedSource(pkg))
            .putExtra(AutofillFillActivity.EXTRA_USERNAME_ID, f.username)
            .putExtra(AutofillFillActivity.EXTRA_PASSWORD_ID, f.password)
        var piFlags = PendingIntent.FLAG_CANCEL_CURRENT
        // The system adds the screen's structure to the intent: must be mutable.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) piFlags = piFlags or PendingIntent.FLAG_MUTABLE
        val pi = PendingIntent.getActivity(this, ++requestCode, intent, piFlags)
        val tr = resources.configuration.locales[0].language == "tr"
        val presentation = RemoteViews(packageName, R.layout.autofill_item).apply {
            setTextViewText(R.id.text, if (tr) "Passlune ile doldur" else "Fill with Passlune")
        }
        val dataset = Dataset.Builder(presentation)
        for (id in ids) dataset.setValue(id, null)
        dataset.setAuthentication(pi.intentSender)

        val response = FillResponse.Builder()
        // The login picked a moment ago on this site's identifier page: offer
        // it ready to fill, no second unlock. Only when the site (browser) or
        // the app (no web content) is known for sure.
        val recentOk = site.isNotEmpty() || !noTag
        if (recentOk) RecentPick.get(pkg, site)?.let { l ->
            val label = if (l.username.isNotEmpty()) "${l.title} · ${l.username}" else l.title
            val ready = Dataset.Builder(RemoteViews(packageName, R.layout.autofill_item).apply {
                setTextViewText(R.id.text, label)
            })
            f.username?.let { ready.setValue(it, AutofillValue.forText(l.username)) }
            f.password?.let { ready.setValue(it, AutofillValue.forText(l.password)) }
            response.addDataset(ready.build())
        }
        callback.onSuccess(
            response
                .addDataset(dataset.build())
                .setSaveInfo(save.build())
                .build()
        )
    }

    private var requestCode = 0

    private fun appLabel(pkg: String): String = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) {
        pkg
    }

    /**
     * Installed by Google Play or part of the system. Only such apps get the
     * reverse-DNS match (com.paypal.android ↔ paypal.com) without a warning:
     * anyone can give a sideloaded app such a package name.
     */
    private fun fromTrustedSource(pkg: String): Boolean = try {
        val ai = packageManager.getApplicationInfo(pkg, 0)
        if (ai.flags and ApplicationInfo.FLAG_SYSTEM != 0) {
            true
        } else {
            val installer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                packageManager.getInstallSourceInfo(pkg).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                packageManager.getInstallerPackageName(pkg)
            }
            installer == "com.android.vending"
        }
    } catch (_: Exception) {
        false
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        try {
            var username: String? = null
            var password: String? = null
            var domain: String? = null
            var pkg: String? = null
            // Oldest to newest: the newest screen wins, earlier screens fill gaps
            // (the e-mail typed on step one of a two-step login).
            for (ctx in request.fillContexts) {
                val s = ctx.structure
                pkg = s.activityComponent.packageName
                val f = parse(s)
                val pw = f.savePasswordValue ?: f.passwordValue
                if (!pw.isNullOrEmpty()) password = pw
                if (!f.usernameValue.isNullOrBlank()) username = f.usernameValue!!.trim()
                if (f.webDomain != null && pkg in BROWSERS) domain = f.webDomain
            }
            if (password.isNullOrEmpty()) return callback.onSuccess()
            val label = try {
                packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg ?: "", 0)).toString()
            } catch (_: Exception) {
                pkg ?: ""
            }
            val json = JSONObject()
                .put("site", domain?.removePrefix("www.") ?: label)
                .put("username", username ?: "")
                .put("password", password)
                .put("app", pkg ?: "")
                .put("appLabel", label)
                .put("web", domain != null)
                .put("ts", System.currentTimeMillis())
            PendingStore.append(this, json.toString())
            val tr = resources.configuration.locales[0].language == "tr"
            Toast.makeText(
                this,
                if (tr) "Passlune'a kaydedildi. Passlune'u açınca kasana eklenecek." else "Saved to Passlune. It will be added when you next open Passlune.",
                Toast.LENGTH_LONG
            ).show()
            callback.onSuccess()
        } catch (e: Exception) {
            callback.onFailure(e.message ?: "Passlune")
        }
    }

    // ------------------------------------------------------------ parsing

    private fun parse(structure: AssistStructure): Fields {
        val f = Fields()
        for (i in 0 until structure.windowNodeCount) visit(structure.getWindowNodeAt(i).rootViewNode, f, null)
        // The site is the one the login fields themselves belong to (an iframe
        // further down the page must not decide it); if the two disagree, none.
        f.webDomain = when {
            f.passwordDomain != null && f.usernameDomain != null && f.passwordDomain != f.usernameDomain -> null
            else -> f.passwordDomain ?: f.usernameDomain
        }
        // Change-password form: several password fields; save the new one
        // (marked new-password, or else the last, which is the confirmation).
        if (f.passwords.size >= 2) {
            f.savePasswordValue = f.passwords.firstOrNull { it.second && !it.first.isNullOrEmpty() }?.first
                ?: f.passwords.last().first
        }
        if (f.password == null) {
            // No password on screen: only an identifier step of a login counts,
            // and only when the field says it's a username or e-mail. A chat
            // box, a search bar or a "phone" field in some form is not a login.
            if (!f.usernameStrong) {
                f.username = null
                f.usernameValue = null
            }
        } else if (f.username == null && f.textFields.isNotEmpty()) {
            // No field calls itself the username: take the last text field
            // before the password (the usual "identifier + password" form).
            val (id, value) = f.textFields.last()
            f.username = id
            f.usernameValue = value
        }
        return f
    }

    private fun visit(node: AssistStructure.ViewNode, f: Fields, parentDomain: String?) {
        // A view's site is its own web domain or the nearest ancestor's.
        val own = node.webDomain?.takeIf { it.isNotBlank() }
        if (own != null) f.anyWeb = true
        val domain = own ?: parentDomain
        val id = node.autofillId
        // The focused field always counts, even if a browser reports it as
        // not visible; hidden helper fields never do.
        if (id != null && node.autofillType == View.AUTOFILL_TYPE_TEXT &&
            (node.visibility == View.VISIBLE || node.isFocused) && !isHiddenHelper(node)) {
            val value = node.autofillValue?.takeIf { it.isText }?.textValue?.toString()
            when {
                isPassword(node) -> {
                    f.passwords.add(value to isNewPassword(node))
                    if (f.password == null) {
                        f.password = id
                        f.passwordValue = value
                        f.passwordDomain = domain
                    }
                }
                isUsername(node) -> if (f.username == null || (!f.usernameStrong && isStrongUsername(node))) {
                    f.username = id
                    f.usernameValue = value
                    f.usernameStrong = isStrongUsername(node)
                    f.usernameDomain = domain
                }
                // Plain text fields before the password: username candidates.
                f.password == null && isPlainText(node) -> f.textFields.add(id to value)
            }
        }
        for (i in 0 until node.childCount) visit(node.getChildAt(i), f, domain)
    }

    private fun isNewPassword(node: AssistStructure.ViewNode): Boolean {
        if (node.autofillHints?.any { it.contains("newPassword", true) } == true) return true
        if (htmlAttr(node, "autocomplete")?.contains("new-password") == true) return true
        val h = hints(node)
        return h.contains("new") || h.contains("yeni")
    }

    private fun hints(node: AssistStructure.ViewNode): String {
        val sb = StringBuilder()
        node.autofillHints?.forEach { sb.append(it).append(' ') }
        node.idEntry?.let { sb.append(it).append(' ') }
        node.hint?.let { sb.append(it).append(' ') }
        node.htmlInfo?.attributes?.forEach { a ->
            if (a.first in listOf("type", "name", "id", "autocomplete", "placeholder", "aria-label")) sb.append(a.second).append(' ')
        }
        return sb.toString().lowercase()
    }

    private fun htmlType(node: AssistStructure.ViewNode): String? =
        node.htmlInfo?.attributes?.firstOrNull { it.first == "type" }?.second?.lowercase()

    private fun htmlAttr(node: AssistStructure.ViewNode, name: String): String? =
        node.htmlInfo?.attributes?.firstOrNull { it.first == name }?.second?.lowercase()

    /**
     * Fields a page keeps out of sight for password managers, like the hidden
     * password box on Google's e-mail step. Counting it would make the system
     * think the password was already handled, and the real password field on
     * the next step would get no "Fill with Passlune".
     */
    private fun isHiddenHelper(node: AssistStructure.ViewNode): Boolean {
        if (node.isFocused) return false
        if (htmlType(node) == "hidden" || htmlAttr(node, "aria-hidden") == "true") return true
        val name = (htmlAttr(node, "name") ?: "") + " " + (htmlAttr(node, "id") ?: "")
        return name.contains("hidden")
    }

    private fun isPassword(node: AssistStructure.ViewNode): Boolean {
        if (htmlType(node) == "password") return true
        if (node.autofillHints?.any { it.contains("password", true) } == true) return true
        val t = node.inputType
        val cls = t and InputType.TYPE_MASK_CLASS
        val variation = t and InputType.TYPE_MASK_VARIATION
        if (cls == InputType.TYPE_CLASS_TEXT && (variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)) return true
        if (cls == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD) {
            // Numeric PIN boxes are OTP/card fields far more often than logins.
            return hints(node).let { it.contains("pass") || it.contains("şifre") || it.contains("sifre") || it.contains("parola") }
        }
        return false
    }

    // Words that on their own mark a login identifier...
    private val strongUsernameWords = Regex("user|login|e-?mail|e-?posta|identifier|kullan")
    // ...and ones that only count next to a password field (forms ask for a
    // phone number or account name for many other reasons).
    private val usernameWords = Regex("user|login|e-?mail|e-?posta|identifier|account|kullan|kimlik|tckn|phone|telefon")

    private fun isMultiLine(node: AssistStructure.ViewNode): Boolean =
        (node.inputType and InputType.TYPE_TEXT_FLAG_MULTI_LINE) != 0 || htmlTag(node) == "textarea"

    private fun htmlTag(node: AssistStructure.ViewNode): String? = node.htmlInfo?.tag?.lowercase()

    private fun isStrongUsername(node: AssistStructure.ViewNode): Boolean {
        if (isMultiLine(node)) return false
        if (node.autofillHints?.any { it.contains("username", true) || it.contains("email", true) } == true) return true
        if (htmlType(node) == "email") return true
        val autocomplete = node.htmlInfo?.attributes?.firstOrNull { it.first == "autocomplete" }?.second?.lowercase()
        if (autocomplete != null && ("username" in autocomplete || "email" in autocomplete)) return true
        val t = node.inputType
        if ((t and InputType.TYPE_MASK_CLASS) == InputType.TYPE_CLASS_TEXT &&
            (t and InputType.TYPE_MASK_VARIATION) in listOf(
                InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS, InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS
            )) return true
        val h = hints(node)
        return strongUsernameWords.containsMatchIn(h) && !h.contains("search")
    }

    private fun isUsername(node: AssistStructure.ViewNode): Boolean {
        if (isMultiLine(node)) return false
        if (isStrongUsername(node)) return true
        if (node.autofillHints?.any { it.contains("phone", true) } == true) return true
        val h = hints(node)
        return usernameWords.containsMatchIn(h) && !h.contains("search")
    }

    private fun isPlainText(node: AssistStructure.ViewNode): Boolean {
        if (isMultiLine(node)) return false
        val type = htmlType(node)
        if (type != null) return type == "text" || type == "tel"
        val h = hints(node)
        if (h.contains("search")) return false
        return (node.inputType and InputType.TYPE_MASK_CLASS) == InputType.TYPE_CLASS_TEXT ||
            (node.inputType and InputType.TYPE_MASK_CLASS) == InputType.TYPE_CLASS_PHONE
    }
}
