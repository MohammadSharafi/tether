package dev.tether.app

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

/** Pick a folder on the computer (inside your home folder) and give Claude a first message. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewSessionScreen(store: Store, back: () -> Unit, started: (String, String) -> Unit) {
    val api = remember(store.server, store.token) { store.api() }
    var path by remember { mutableStateOf<String?>(null) }
    var listing by remember { mutableStateOf<FolderListing?>(null) }
    var prompt by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var starting by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(path) { runCatching { api.folders(path) }.onSuccess { listing = it; error = null }.onFailure { error = it.message } }

    Scaffold(containerColor = Bg, topBar = {
        TopAppBar(navigationIcon = { IconButton(onClick = back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            title = { Text("New session", fontWeight = FontWeight.Bold) }, colors = TopAppBarDefaults.topAppBarColors(containerColor = Bg))
    }) { pad ->
        Column(Modifier.fillMaxSize().padding(pad).imePadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Folder", color = Muted, fontWeight = FontWeight.SemiBold)
            Text(listing?.path ?: "Loading…", fontSize = 13.sp, color = Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            LazyColumn(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Card)) {
                listing?.parent?.let { p -> item { FolderRow(".. (up)", false) { path = p } } }
                items(listing?.dirs ?: emptyList()) { f -> FolderRow(f.name, f.repo) { path = f.path } }
            }
            error?.let { Text(it, color = Warn, fontSize = 13.sp) }
            OutlinedTextField(prompt, { prompt = it }, Modifier.fillMaxWidth(), label = { Text("What should Claude do?") }, minLines = 2, maxLines = 5)
            Button(onClick = {
                val cwd = listing?.path ?: return@Button
                starting = true
                scope.launch {
                    try { started(api.start(cwd, prompt), prompt.take(60)) } catch (e: Exception) { error = e.message }
                    starting = false
                }
            }, Modifier.fillMaxWidth(), enabled = listing != null && prompt.isNotBlank() && !starting,
                colors = ButtonDefaults.buttonColors(containerColor = Coral)) { Text(if (starting) "Starting…" else "Start in this folder", color = Color.White) }
        }
    }
}

@Composable
private fun FolderRow(name: String, repo: Boolean, onClick: () -> Unit) =
    Text((if (repo) "◆  " else "▸  ") + name, Modifier.fillMaxWidth().clickable(onClick = onClick).padding(16.dp, 13.dp), fontSize = 16.sp,
        color = if (repo) Coral else Color(0xFFF2F2F5))
