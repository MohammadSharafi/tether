package dev.tether.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue

sealed interface Screen {
    data object List : Screen
    data class Chat(val id: String, val title: String?) : Screen
    data object Settings : Screen
    data object NewSession : Screen
}

class MainActivity : ComponentActivity() {
    private val link = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        link.value = intent?.dataString
        val store = Store(applicationContext)
        setContent { TetherTheme { App(store, link.value) { link.value = null } } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        link.value = intent.dataString
    }
}

@Composable
fun App(store: Store, link: String?, consumeLink: () -> Unit) {
    var screen by remember { mutableStateOf<Screen>(if (store.configured) Screen.List else Screen.Settings) }
    val pairing = link?.let { Api.pairing(it) }

    // The app asks before connecting to a server from a pairing link.
    if (pairing != null) {
        AlertDialog(
            onDismissRequest = consumeLink,
            title = { Text("Connect to this computer?") },
            text = { Text("Tether will connect to ${pairing.first}. Only continue if you scanned the QR code from your own computer.") },
            confirmButton = { TextButton(onClick = { store.save(pairing.first, pairing.second); consumeLink(); screen = Screen.List }) { Text("Connect") } },
            dismissButton = { TextButton(onClick = consumeLink) { Text("Cancel") } },
        )
    } else if (link != null) consumeLink()

    BackHandler(enabled = screen != Screen.List && store.configured) { screen = Screen.List }
    when (val s = screen) {
        Screen.List -> SessionsScreen(store, open = { id, title -> screen = Screen.Chat(id, title) },
            settings = { screen = Screen.Settings }, newSession = { screen = Screen.NewSession })
        is Screen.Chat -> SessionScreen(store, s.id, s.title, back = { screen = Screen.List })
        Screen.Settings -> SettingsScreen(store, done = { if (store.configured) screen = Screen.List })
        Screen.NewSession -> NewSessionScreen(store, back = { screen = Screen.List }, started = { id, title -> screen = Screen.Chat(id, title) })
    }
}
