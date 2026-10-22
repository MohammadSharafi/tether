package dev.tether.app

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Everything one open session shows. Lives as long as the screen. */
class ChatModel(private val api: Api, val id: String) {
    val events = mutableStateListOf<Event>()
    val decided = mutableStateMapOf<String, Boolean>()
    var state by mutableStateOf<String?>(null)
    var streaming by mutableStateOf("")
    var error by mutableStateOf<String?>(null)
    var loaded by mutableStateOf(false)
    var running by mutableStateOf<ComputerRun?>(null)
    private var lastSeq = 0
    private var stream: Job? = null

    val live get() = state != null && state != "closed"
    val busy get() = state == "running" || state == "waiting"

    suspend fun read() {
        val d = api.detail(id)
        events.clear(); decided.clear(); streaming = ""
        d.events.forEach(::apply)
        state = d.state; lastSeq = d.seq; error = null; loaded = true
    }

    /** Reads the session, retrying every 3 s until it works (a phone on the move drops requests now and then). */
    suspend fun load() {
        while (true) {
            try { read(); return } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message; loaded = true }
            delay(3_000)
        }
    }

    fun apply(e: Event) {
        e.seq?.let { lastSeq = it }
        when (e.kind) {
            "status" -> state = if (e.state == "closed") null else e.state
            "permissionResolved" -> e.requestId?.let { decided[it] = e.allow ?: false }
            "delta" -> streaming += e.text ?: ""
            "settings" -> Unit
            else -> { if (e.kind in listOf("assistant", "tool", "permission", "result")) streaming = ""; events.add(e) }
        }
    }

    /** Follows the live stream; when the connection drops, reads the session again and reconnects. */
    fun follow(scope: kotlinx.coroutines.CoroutineScope) {
        if (stream?.isActive == true) return
        stream = scope.launch {
            while (isActive && live) {
                try { api.events(id, lastSeq).collect { apply(it) }; break }
                catch (e: CancellationException) { throw e }
                catch (e: Exception) {
                    error = e.message; delay(3_000)
                    runCatching { read() }
                }
            }
        }
    }

    /** Re-reads a session that runs on the computer; keeps the rows when nothing changed. */
    suspend fun refresh() {
        val d = runCatching { api.detail(id) }.getOrNull() ?: return
        if (d.events.size != events.size || d.events.lastOrNull()?.text != events.lastOrNull()?.text) {
            events.clear(); d.events.forEach(::apply)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionScreen(store: Store, id: String, title: String?, back: () -> Unit) {
    val api = remember(store.server, store.token) { store.api() }
    val model = remember(id) { ChatModel(api, id) }
    val scope = rememberCoroutineScope()
    var draft by remember { mutableStateOf("") }
    var pending by remember { mutableStateOf<String?>(null) }   // a message waiting for "Continue here"
    var attempt by remember { mutableIntStateOf(0) }

    LaunchedEffect(id, attempt) {
        model.load()
        if (model.live) model.follow(this)
        // Watch whether it runs in the desktop app or a terminal, and keep such a session up to date.
        while (true) {
            delay(4_000)
            if (model.live) continue
            model.running = runCatching { api.sessions().firstOrNull { it.id == id }?.running }.getOrDefault(model.running)
            if (model.running != null) model.refresh()
        }
    }

    fun send(text: String) {
        if (text.isBlank()) return
        if (!model.live && model.running != null) { pending = text; return }
        scope.launch {
            try {
                val wasLive = model.live
                api.send(id, text)
                if (!wasLive) { model.state = "running"; model.running = null }
                model.follow(scope)
            } catch (e: Exception) { model.error = e.message; if (draft.isEmpty()) draft = text }
        }
    }

    pending?.let { text ->
        AlertDialog(
            onDismissRequest = { pending = null; if (draft.isEmpty()) draft = text },
            title = { Text("Continue this chat on your phone?") },
            text = { Text("It is open in the ${model.running?.place ?: "computer"}. Tether stops it there first, like pressing Ctrl-C, then sends your message. Reopen it on the computer later to see the new messages.") },
            confirmButton = {
                TextButton(onClick = {
                    pending = null
                    scope.launch {
                        try {
                            api.stopOnComputer(id)
                            // Wait for the process to exit; the server refuses the message while it runs.
                            for (i in 0 until 10) {
                                delay(1_000)
                                if (api.sessions().firstOrNull { it.id == id }?.running == null) break
                            }
                        } catch (e: Exception) { model.error = e.message }
                        model.running = null
                        send(text)
                    }
                }) { Text("Continue here") }
            },
            dismissButton = { TextButton(onClick = { pending = null; if (draft.isEmpty()) draft = text }) { Text("Cancel") } },
        )
    }

    Scaffold(
        containerColor = Bg,
        topBar = {
            TopAppBar(
                navigationIcon = { IconButton(onClick = back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                title = {
                    Column {
                        Text(title ?: "Session", maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                        status(model.state, if (model.live) null else model.running)?.let { Text(it.text, color = it.color, fontSize = 12.sp) }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Bg),
            )
        },
        bottomBar = { Composer(model, draft, { draft = it }, ::send) { scope.launch { runCatching { api.interrupt(id) } } } },
    ) { pad ->
        Box(Modifier.fillMaxSize().padding(pad)) {
            if (!model.loaded) {
                CircularProgressIndicator(Modifier.align(Alignment.Center), color = Coral)
            } else if (model.events.isEmpty() && model.error != null) {
                Column(Modifier.align(Alignment.Center).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Can't load this session", fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                    Text(model.error ?: "", color = Muted, modifier = Modifier.padding(8.dp))
                    TextButton(onClick = { attempt++ }) { Text("Try again") }
                }
            }
            // Newest at the bottom: a reversed list starts there and stays there as rows arrive.
            LazyColumn(Modifier.fillMaxSize(), reverseLayout = true, contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                model.error?.takeIf { model.events.isNotEmpty() }?.let { e ->
                    item { Row(verticalAlignment = Alignment.CenterVertically) { Text(e, color = MaterialThemeError, fontSize = 13.sp, modifier = Modifier.weight(1f)); TextButton(onClick = { attempt++ }) { Text("Try again") } } }
                }
                if (model.streaming.isNotEmpty()) item { Markdown(model.streaming + " ▍") }
                items(model.events.reversed(), key = { it.key }) { e -> EventRow(e, model, api, scope) }
            }
        }
    }
}

private val MaterialThemeError = Color(0xFFFF6B6B)

@Composable
private fun Composer(model: ChatModel, draft: String, setDraft: (String) -> Unit, send: (String) -> Unit, stop: () -> Unit) {
    Column(Modifier.fillMaxWidth().background(Color(0xFF141418)).navigationBarsPadding().imePadding().padding(horizontal = 12.dp, vertical = 8.dp)) {
        model.running?.takeIf { !model.live }?.let {
            Text("Open in the ${it.place} on your computer. Updates appear here live; send a message to continue it here.", color = Muted, fontSize = 13.sp, modifier = Modifier.padding(4.dp, 0.dp, 4.dp, 8.dp))
        }
        if (draft.isEmpty() && !model.busy && model.loaded) {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("Continue", "Yes, go ahead", "Run the tests", "Explain what you changed").forEach { r ->
                    Text(r, Modifier.clip(CircleShape).background(CardHigh).clickable { send(r) }.padding(14.dp, 8.dp), fontSize = 14.sp)
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextField(draft, setDraft, Modifier.weight(1f).clip(RoundedCornerShape(22.dp)), placeholder = { Text("Message") }, maxLines = 6,
                colors = TextFieldDefaults.colors(focusedContainerColor = Card, unfocusedContainerColor = Card, focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent))
            if (model.busy && draft.isBlank()) {
                IconButton(onClick = stop) { Icon(Icons.Default.Close, "Stop", tint = MaterialThemeError) }
            } else {
                IconButton(onClick = { val t = draft; setDraft(""); send(t) }, enabled = draft.isNotBlank()) {
                    Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = if (draft.isNotBlank()) Coral else Muted)
                }
            }
        }
    }
}

@Composable
private fun EventRow(e: Event, model: ChatModel, api: Api, scope: kotlinx.coroutines.CoroutineScope) {
    when (e.kind) {
        "user" -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Text(e.text ?: "", Modifier.widthIn(max = 300.dp).clip(RoundedCornerShape(20.dp)).background(Coral).padding(14.dp, 10.dp), color = Color.White, fontSize = 16.sp)
        }
        "assistant" -> Markdown(e.text ?: "")
        "tool" -> ToolRow(e)
        "permission" -> PermissionCard(e, model, api, scope)
        "result" -> Text(if (e.isError == true) "Stopped with an error" else "Done" + (e.cost?.takeIf { it > 0 }?.let { " · $%.2f".format(it) } ?: ""), color = Muted, fontSize = 13.sp)
        "notice" -> Text(e.text ?: "", color = Warn, fontSize = 14.sp)
        "meta" -> Text(e.text ?: "", color = Muted, fontSize = 13.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
        else -> Unit
    }
}

@Composable
private fun ToolRow(e: Event) {
    var open by remember { mutableStateOf(false) }
    val diff = e.oldString != null || e.newString != null
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Card).clickable(enabled = diff) { open = !open }.padding(12.dp, 10.dp)) {
        Row {
            Text(e.name ?: "Tool", fontWeight = FontWeight.SemiBold, color = Muted, fontSize = 14.sp)
            Spacer(Modifier.size(8.dp))
            Text(e.text ?: e.filePath ?: "", fontFamily = FontFamily.Monospace, color = Muted, fontSize = 13.sp, maxLines = if (open) 10 else 1, overflow = TextOverflow.Ellipsis)
        }
        if (open) {
            Spacer(Modifier.size(8.dp))
            e.oldString?.lines()?.forEach { Text("- $it", Modifier.fillMaxWidth().background(Color(0x55A33A3A)).padding(4.dp, 1.dp), fontFamily = FontFamily.Monospace, fontSize = 12.sp) }
            e.newString?.lines()?.forEach { Text("+ $it", Modifier.fillMaxWidth().background(Color(0x553A7A45)).padding(4.dp, 1.dp), fontFamily = FontFamily.Monospace, fontSize = 12.sp) }
        }
    }
}

@Composable
private fun PermissionCard(e: Event, model: ChatModel, api: Api, scope: kotlinx.coroutines.CoroutineScope) {
    val req = e.requestId ?: ""
    val decision = model.decided[req]
    var sending by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color(0xFF1E1714))
        .border(1.dp, Coral.copy(alpha = if (decision == null && model.live) .6f else .2f), RoundedCornerShape(18.dp)).padding(16.dp)) {
        Text(e.title ?: "Claude wants to use ${e.name ?: "a tool"}", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        e.description?.let { Text(it, color = Muted, fontSize = 13.sp, modifier = Modifier.padding(top = 6.dp)) }
        (e.command ?: e.filePath ?: e.text)?.let {
            Text(it, Modifier.padding(top = 10.dp).fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(Card).padding(10.dp), fontFamily = FontFamily.Monospace, fontSize = 14.sp)
        }
        Spacer(Modifier.size(12.dp))
        when {
            decision != null -> Text(if (decision) "Allowed" else "Denied", color = if (decision) Good else MaterialThemeError, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            !model.live -> Text("No longer waiting", color = Muted, fontSize = 13.sp)
            else -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                fun decide(allow: Boolean) {
                    sending = true
                    scope.launch {
                        try { api.decide(model.id, req, allow); model.decided[req] = allow } catch (x: Exception) { model.error = x.message }
                        sending = false
                    }
                }
                OutlinedButton(onClick = { decide(false) }, enabled = !sending) { Text("Deny", color = MaterialThemeError) }
                Button(onClick = { decide(true) }, enabled = !sending, colors = ButtonDefaults.buttonColors(containerColor = Coral)) { Text("Allow", color = Color.White) }
            }
        }
    }
}

/** Just enough Markdown for replies: **bold**, `code` and list lines. */
@Composable
fun Markdown(text: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        text.lines().forEach { raw ->
            val bullet = raw.trimStart().let { it.startsWith("- ") || it.startsWith("* ") }
            val line = if (bullet) "•  " + raw.trimStart().drop(2) else raw
            Text(inline(line), fontSize = 16.sp, lineHeight = 23.sp)
        }
    }
}

private fun inline(s: String): AnnotatedString = buildAnnotatedString {
    var i = 0
    while (i < s.length) {
        when {
            s.startsWith("**", i) && s.indexOf("**", i + 2) > 0 -> { val j = s.indexOf("**", i + 2); pushStyle(SpanStyle(fontWeight = FontWeight.Bold)); append(s.substring(i + 2, j)); pop(); i = j + 2 }
            s[i] == '`' && s.indexOf('`', i + 1) > 0 -> { val j = s.indexOf('`', i + 1); pushStyle(SpanStyle(fontFamily = FontFamily.Monospace, background = Color(0xFF26262C))); append(s.substring(i + 1, j)); pop(); i = j + 1 }
            else -> { append(s[i]); i++ }
        }
    }
}
