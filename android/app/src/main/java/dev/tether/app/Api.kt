package dev.tether.app

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** A session running on the computer outside this app (desktop app or terminal). */
data class ComputerRun(val source: String, val working: Boolean) {
    val place get() = if (source == "desktop") "desktop app" else "terminal"
}

data class Session(
    val id: String, val title: String?, val cwd: String?, val branch: String?,
    val updated: Double, val state: String?, val running: ComputerRun?,
) {
    val folder get() = cwd?.trimEnd('/', '\\')?.substringAfterLast('/')?.substringAfterLast('\\') ?: "Other"
}

/** One line in a session. History and the live stream share this shape. */
data class Event(
    val kind: String, val text: String?, val name: String?, val title: String?,
    val requestId: String?, val command: String?, val description: String?, val filePath: String?,
    val oldString: String?, val newString: String?, val cost: Double?, val isError: Boolean?,
    val allow: Boolean?, val state: String?, val seq: Int?,
) {
    /** Row identity: history events carry no server id. */
    val key = Any()
}

data class Detail(val state: String?, val seq: Int, val events: List<Event>)
data class PlanWindow(val utilization: Double, val resetsAt: String?)
data class Plan(val available: Boolean, val fiveHour: PlanWindow?, val sevenDay: PlanWindow?)
data class Folder(val name: String, val path: String, val repo: Boolean)
data class FolderListing(val path: String, val parent: String?, val dirs: List<Folder>)

class ApiError(message: String) : Exception(message)

private fun JSONObject.str(k: String) = if (isNull(k) || !has(k)) null else optString(k)
private fun JSONObject.num(k: String) = if (isNull(k) || !has(k)) null else optDouble(k)
private fun JSONObject.bool(k: String) = if (isNull(k) || !has(k)) null else optBoolean(k)

fun parseEvent(o: JSONObject): Event {
    val input = o.optJSONObject("input")
    return Event(
        kind = o.optString("kind"), text = o.str("text"), name = o.str("name"), title = o.str("title"),
        requestId = o.str("id"), command = input?.str("command"), description = input?.str("description"),
        filePath = input?.str("file_path"), oldString = input?.str("old_string"), newString = input?.str("new_string"),
        cost = o.num("cost"), isError = o.bool("isError"), allow = o.bool("allow"), state = o.str("state"),
        seq = if (o.has("seq") && !o.isNull("seq")) o.optInt("seq") else null,
    )
}

fun parseSession(o: JSONObject) = Session(
    id = o.getString("id"), title = o.str("title"), cwd = o.str("cwd"), branch = o.str("branch"),
    updated = o.optDouble("updated", 0.0), state = o.str("state"),
    running = o.optJSONObject("mac")?.let { ComputerRun(it.optString("source"), it.optBoolean("working")) },
)

private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }

/** Talks to the Tether server on your computer. Same endpoints as the iPhone app. */
class Api(private val base: String, private val token: String) {
    private fun url(path: String) = URL(base.trim().trimEnd('/') + path)

    private suspend fun call(path: String, method: String = "GET", body: JSONObject? = null, timeoutMs: Int = 30_000): String =
        withContext(Dispatchers.IO) {
            val c = try { url(path).openConnection() as HttpURLConnection } catch (e: Exception) { throw ApiError("Invalid server address.") }
            try {
                c.requestMethod = method
                c.connectTimeout = timeoutMs; c.readTimeout = timeoutMs
                c.setRequestProperty("Authorization", "Bearer $token")
                if (body != null) {
                    c.doOutput = true
                    c.setRequestProperty("Content-Type", "application/json")
                    c.outputStream.use { it.write(body.toString().toByteArray()) }
                }
                val code = c.responseCode
                val text = (if (code in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
                // Tailscale answers for the computer when the Tether server itself is restarting or stopped.
                if (code in listOf(502, 503, 504)) throw ApiError("Tether on your computer is not answering. Retrying…")
                if (code !in 200..299) {
                    val msg = runCatching { JSONObject(text).optString("error") }.getOrNull()
                    throw ApiError(if (msg.isNullOrBlank()) "Your computer returned error $code." else msg)
                }
                text
            } catch (e: IOException) {
                throw ApiError("Can't reach your computer. Check that it's awake and on Tailscale.")
            } finally { c.disconnect() }
        }

    suspend fun sessions(): List<Session> = JSONArray(call("/sessions")).objects().map(::parseSession)

    // The computer answers in well under a second; a short timeout turns a dead connection into a quick retry.
    suspend fun detail(id: String): Detail {
        val o = JSONObject(call("/sessions/$id", timeoutMs = 10_000))
        return Detail(o.str("state"), o.optInt("seq"), o.getJSONArray("events").objects().map(::parseEvent))
    }

    suspend fun plan(): Plan {
        val o = JSONObject(call("/plan"))
        fun w(k: String) = o.optJSONObject(k)?.let { PlanWindow(it.optDouble("utilization"), it.str("resetsAt")) }
        return Plan(o.optBoolean("available"), w("fiveHour"), w("sevenDay"))
    }

    suspend fun folders(path: String?): FolderListing {
        val q = path?.let { "?path=" + URLEncoder.encode(it, "UTF-8") } ?: ""
        val o = JSONObject(call("/folders$q"))
        return FolderListing(o.getString("path"), o.str("parent"),
            o.getJSONArray("dirs").objects().map { Folder(it.getString("name"), it.getString("path"), it.optBoolean("repo")) })
    }

    suspend fun start(cwd: String, prompt: String): String =
        JSONObject(call("/sessions", "POST", JSONObject().put("cwd", cwd).put("text", prompt))).getString("id")

    suspend fun send(id: String, text: String) { call("/sessions/$id/messages", "POST", JSONObject().put("text", text)) }

    suspend fun decide(id: String, request: String, allow: Boolean, message: String? = null) {
        val body = JSONObject().put("allow", allow)
        if (message != null) body.put("message", message)
        call("/sessions/$id/permissions/$request", "POST", body)
    }

    suspend fun interrupt(id: String) { call("/sessions/$id/interrupt", "POST") }
    suspend fun stopOnComputer(id: String) { call("/sessions/$id/stop-mac", "POST") }

    /** Live events after `after`. Ends when the server closes the stream; throws when the connection drops. */
    fun events(id: String, after: Int): Flow<Event> = flow {
        val c = url("/sessions/$id/events?after=$after").openConnection() as HttpURLConnection
        try {
            c.setRequestProperty("Authorization", "Bearer $token")
            c.connectTimeout = 10_000
            c.readTimeout = 60_000 // the server sends a ping every 25 s, so silence means the connection is gone
            if (c.responseCode != 200) throw ApiError("Session is not live.")
            c.inputStream.bufferedReader().use { r ->
                while (true) {
                    val line = r.readLine() ?: break
                    if (line.startsWith("data: ")) emit(parseEvent(JSONObject(line.substring(6))))
                }
            }
        } catch (e: IOException) {
            throw ApiError("Live updates were interrupted. Reconnecting…")
        } finally { c.disconnect() }
    }.flowOn(Dispatchers.IO)

    companion object {
        /** Parses a pairing link (tether://pair?url=…&token=…) from the QR code the computer shows. */
        fun pairing(link: String): Pair<String, String>? {
            val uri = android.net.Uri.parse(link)
            if (uri.scheme != "tether" || uri.host != "pair") return null
            val server = uri.getQueryParameter("url") ?: return null
            val token = uri.getQueryParameter("token") ?: return null
            val parsed = android.net.Uri.parse(server)
            if (parsed.scheme !in listOf("https", "http") || parsed.host.isNullOrEmpty() || token.isEmpty()) return null
            return server to token
        }
    }
}
