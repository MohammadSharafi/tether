package dev.tether.app

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/** Server address and token. The token is encrypted with a key kept in the Android Keystore. */
class Store(context: Context) {
    private val prefs = EncryptedSharedPreferences.create(
        context, "tether",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )
    var server by mutableStateOf(prefs.getString("server", "") ?: "")
        private set
    var token by mutableStateOf(prefs.getString("token", "") ?: "")
        private set

    val configured get() = server.isNotBlank() && token.isNotBlank()
    fun api() = Api(server, token)

    fun save(server: String, token: String) {
        prefs.edit().putString("server", server.trim()).putString("token", token.trim()).apply()
        this.server = server.trim(); this.token = token.trim()
    }
}
