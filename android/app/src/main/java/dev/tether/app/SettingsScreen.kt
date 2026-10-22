package dev.tether.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(store: Store, done: () -> Unit) {
    var server by remember { mutableStateOf(store.server) }
    var token by remember { mutableStateOf(store.token) }
    var status by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Scaffold(containerColor = Bg, topBar = { TopAppBar(title = { Text("Settings", fontWeight = FontWeight.Bold) }, colors = TopAppBarDefaults.topAppBarColors(containerColor = Bg)) }) { pad ->
        Column(Modifier.fillMaxSize().padding(pad).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("Pair with your computer", color = Muted, fontWeight = FontWeight.SemiBold)
            Text("On your computer, run  npm run pair  in the server folder, then scan the QR code with your phone's camera.",
                Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Card).padding(16.dp), fontSize = 15.sp)
            Text("Or enter it by hand", color = Muted, fontWeight = FontWeight.SemiBold)
            OutlinedTextField(server, { server = it }, Modifier.fillMaxWidth(), label = { Text("Server address") }, singleLine = true,
                placeholder = { Text("https://your-computer.your-tailnet.ts.net") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            OutlinedTextField(token, { token = it }, Modifier.fillMaxWidth(), label = { Text("Token") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation())
            OutlinedButton(onClick = {
                status = "Testing…"
                scope.launch { status = runCatching { "Connected. ${Api(server, token).sessions().size} sessions." }.getOrElse { it.message } }
            }, enabled = server.isNotBlank() && token.isNotBlank()) { Text("Test connection") }
            status?.let { Text(it, color = if (it.startsWith("Connected")) Good else Muted, fontSize = 14.sp) }
            Button(onClick = { store.save(server, token); done() }, Modifier.fillMaxWidth(), enabled = server.isNotBlank() && token.isNotBlank(),
                colors = ButtonDefaults.buttonColors(containerColor = Coral)) { Text("Save", color = Color.White) }
            Text("The token is like a password for your computer. It is stored encrypted on this phone.", color = Muted, fontSize = 13.sp)
        }
    }
}
