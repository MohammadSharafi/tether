package dev.tether.app

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import java.time.Duration
import java.time.Instant

/** What a session is doing, as one short colored line. */
data class Status(val text: String, val color: Color)

fun status(state: String?, running: ComputerRun?): Status? = when {
    state == "waiting" -> Status("Needs you", Warn)
    state == "running" -> Status("Working", Coral)
    state == "idle" -> Status("Ready for your next message", Good)
    running != null -> Status(if (running.working) "Working in the ${running.place}" else "Open in the ${running.place}", Muted)
    else -> null
}

fun ago(ms: Double): String {
    val s = (System.currentTimeMillis() - ms) / 1000
    return when {
        s < 60 -> "now"; s < 3600 -> "${(s / 60).toInt()} min ago"; s < 86_400 -> "${(s / 3600).toInt()} hr ago"
        s < 172_800 -> "yesterday"; else -> "${(s / 86_400).toInt()} days ago"
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionsScreen(store: Store, open: (String, String?) -> Unit, settings: () -> Unit, newSession: () -> Unit) {
    var sessions by remember { mutableStateOf<List<Session>?>(null) }
    var plan by remember { mutableStateOf<Plan?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var retry by remember { mutableIntStateOf(0) }

    // Keep the list fresh while it is showing; plan limits change slowly, so about once a minute.
    LaunchedEffect(store.server, store.token, retry) {
        var tick = 0
        while (true) {
            try { sessions = store.api().sessions(); error = null } catch (e: Exception) { error = e.message }
            if (tick % 8 == 0) plan = runCatching { store.api().plan() }.getOrNull()
            tick++
            delay(8_000)
        }
    }

    Scaffold(
        containerColor = Bg,
        topBar = {
            TopAppBar(
                title = { Text("Tether", fontWeight = FontWeight.Bold) },
                actions = {
                    IconButton(onClick = settings) { Icon(Icons.Default.Settings, "Settings") }
                    IconButton(onClick = newSession) { Icon(Icons.Default.Add, "New session") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Bg),
            )
        },
    ) { pad ->
        val list = sessions
        LazyColumn(Modifier.fillMaxSize().padding(pad), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp, 4.dp, 16.dp, 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            error?.let { msg ->
                item {
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Warn.copy(alpha = .15f)).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(msg, Modifier.weight(1f), fontSize = 14.sp)
                        TextButton(onClick = { retry++ }) { Text("Retry") }
                    }
                }
            }
            plan?.takeIf { it.available }?.let { p -> item { PlanMeter(p) } }
            if (list == null) {
                item { Text(if (error == null) "Loading…" else "", color = Muted, modifier = Modifier.padding(24.dp)) }
                return@LazyColumn
            }
            val active = list.filter { it.state != null || it.running != null }
            if (active.isNotEmpty()) {
                item { Section("Active now") }
                item { Group(active, open, showFolder = true) }
            }
            list.filter { it !in active }.groupBy { it.folder }.toList()
                .sortedByDescending { (_, s) -> s.maxOf { it.updated } }
                .forEach { (folder, items) ->
                    item { Section(folder) }
                    item { Group(items, open, showFolder = false) }
                }
            if (list.isEmpty()) item { Text("No sessions yet. Start one with the + button.", color = Muted, modifier = Modifier.padding(24.dp)) }
        }
    }
}

@Composable
private fun Section(title: String) =
    Text(title, color = Muted, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, modifier = Modifier.padding(start = 6.dp, top = 8.dp))

@Composable
private fun Group(items: List<Session>, open: (String, String?) -> Unit, showFolder: Boolean) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Card)) {
        items.forEachIndexed { i, s ->
            if (i > 0) HorizontalDivider(Modifier.padding(start = 64.dp), color = CardHigh)
            Row(Modifier.fillMaxWidth().clickable { open(s.id, s.title) }.padding(14.dp), verticalAlignment = Alignment.Top) {
                Box(Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(Color(0xFF3E87A8)), contentAlignment = Alignment.Center) {
                    Text(s.folder.take(1).uppercase(), fontWeight = FontWeight.Bold, color = Color.White)
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(s.title ?: "Untitled session", fontWeight = FontWeight.SemiBold, fontSize = 16.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    status(s.state, s.running)?.let { Text(it.text, color = it.color, fontSize = 13.sp, fontWeight = FontWeight.Medium) }
                    val meta = listOfNotNull(s.folder.takeIf { showFolder }, s.branch).joinToString("  ·  ")
                    if (meta.isNotEmpty()) Text(meta, color = Muted, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Text(ago(s.updated), color = Muted, fontSize = 12.sp)
            }
        }
    }
}

@Composable
fun PlanMeter(p: Plan) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Card).padding(14.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        listOf("5-hour" to p.fiveHour, "Week" to p.sevenDay).forEach { (label, w) ->
            Column(Modifier.weight(1f)) {
                Row { Text(label, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, modifier = Modifier.weight(1f)); Text("${(w?.utilization ?: 0.0).toInt()}%", color = Coral, fontSize = 14.sp) }
                Spacer(Modifier.height(6.dp))
                LinearProgressIndicator(progress = { ((w?.utilization ?: 0.0) / 100).toFloat().coerceIn(0f, 1f) }, Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)),
                    color = Coral, trackColor = CardHigh, drawStopIndicator = {})
                Spacer(Modifier.height(4.dp))
                Text(resets(w?.resetsAt), color = Muted, fontSize = 12.sp)
            }
        }
    }
}

private fun resets(iso: String?): String {
    val at = iso?.let { runCatching { Instant.parse(it) }.getOrNull() } ?: return ""
    val m = Duration.between(Instant.now(), at).toMinutes()
    return when { m <= 0 -> "Resetting"; m < 60 -> "Resets in $m min"; m < 48 * 60 -> "Resets in ${m / 60} hours"; else -> "Resets in ${m / 1440} days" }
}
