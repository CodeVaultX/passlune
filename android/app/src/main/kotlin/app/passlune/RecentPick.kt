package app.passlune

import android.os.SystemClock

/**
 * The login picked in "Fill with Passlune", kept in memory for a few minutes
 * so the next step of a two-step sign-in (identifier page, then password
 * page) fills without unlocking the vault again. Only for the same app and
 * site; never written to disk, and gone when the app process ends or the
 * time runs out.
 */
object RecentPick {
    private const val TTL_MS = 3 * 60 * 1000L

    class Login(val title: String, val username: String, val password: String)

    private var pkg: String? = null
    private var site: String? = null
    private var login: Login? = null
    private var at = 0L

    @Synchronized
    fun remember(pkg: String, site: String, login: Login) {
        this.pkg = pkg
        this.site = site
        this.login = login
        at = SystemClock.elapsedRealtime()
    }

    /** The pick for this app and site while it's fresh, else null. */
    @Synchronized
    fun get(pkg: String, site: String): Login? {
        val l = login ?: return null
        if (SystemClock.elapsedRealtime() - at > TTL_MS) {
            clear()
            return null
        }
        return if (pkg == this.pkg && site == this.site) l else null
    }

    @Synchronized
    fun clear() {
        login = null
        pkg = null
        site = null
    }
}
