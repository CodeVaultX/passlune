package app.passlune

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Logins captured by the autofill service while the vault is locked. The
 * vault key only exists while the app has it unlocked, so a new login can't
 * go straight into the vault: it waits here, encrypted with an AES key that
 * lives in the Android Keystore (never leaves it, not exportable), until the
 * app is next unlocked and imports it.
 *
 * The key is only usable while the device is unlocked (Android 9+): saving
 * and importing both happen with the screen unlocked, and a process running
 * as this app while the phone sits locked can't decrypt what waits here.
 */
object PendingStore {
    private const val ALIAS = "passlune_autofill_pending_v2"
    /** Key of earlier builds, usable while locked too: still read, never written. */
    private const val OLD_ALIAS = "passlune_autofill_pending"
    private const val FILE = "autofill_pending.txt"

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun existingKey(alias: String): SecretKey? =
        (keyStore().getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.secretKey

    private fun key(): SecretKey {
        existingKey(ALIAS)?.let { return it }
        fun generate(unlockedOnly: Boolean): SecretKey {
            val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
            if (unlockedOnly && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) spec.setUnlockedDeviceRequired(true)
            val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            gen.init(spec.build())
            return gen.generateKey()
        }
        return try {
            generate(unlockedOnly = true)
        } catch (_: Exception) {
            // A Keystore that refuses the restriction: still encrypted, as before.
            generate(unlockedOnly = false)
        }
    }

    @Synchronized
    fun append(context: Context, json: String) {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val ct = c.doFinal(json.toByteArray(Charsets.UTF_8))
        val line = Base64.encodeToString(c.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(ct, Base64.NO_WRAP)
        File(context.filesDir, FILE).appendText(line + "\n")
    }

    /**
     * Decrypts everything waiting, without removing it: the app calls [drop]
     * only after the logins are safely in the vault, so a failed or killed
     * import loses nothing. Unreadable lines come back as null.
     */
    @Synchronized
    fun peekAll(context: Context): List<String?> {
        val f = File(context.filesDir, FILE)
        if (!f.exists()) return emptyList()
        val keys = listOfNotNull(key(), existingKey(OLD_ALIAS))
        return f.readLines().filter { it.isNotBlank() }.map { line ->
            val parts = line.split(":")
            keys.firstNotNullOfOrNull { k ->
                try {
                    val c = Cipher.getInstance("AES/GCM/NoPadding")
                    c.init(Cipher.DECRYPT_MODE, k, GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
                    String(c.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8)
                } catch (_: Exception) {
                    null
                }
            }
        }
    }

    /** Removes the first [count] records (those [peekAll] returned and the app saved). */
    @Synchronized
    fun drop(context: Context, count: Int) {
        val f = File(context.filesDir, FILE)
        if (!f.exists()) return
        val rest = f.readLines().filter { it.isNotBlank() }.drop(count)
        if (rest.isEmpty()) {
            f.delete()
            // Nothing left under the old key: it goes too.
            try {
                keyStore().deleteEntry(OLD_ALIAS)
            } catch (_: Exception) {
            }
        } else {
            f.writeText(rest.joinToString("\n", postfix = "\n"))
        }
    }

    fun count(context: Context): Int {
        val f = File(context.filesDir, FILE)
        return if (f.exists()) f.readLines().count { it.isNotBlank() } else 0
    }
}
