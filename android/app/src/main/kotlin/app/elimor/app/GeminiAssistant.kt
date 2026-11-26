package app.elimor.app

import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Sends the spoken clip to Gemini's Interactions API and gets a short spoken-style answer back. One plain HTTPS POST
 * with the WAV inline as base64; no SDK, no dependency. Runs on a background thread. generateContent is legacy and
 * the new flash models 503 or hang on it, so this uses /v1beta/interactions with the Api-Revision header.
 */
object GeminiAssistant {
    private const val URL = "https://generativelanguage.googleapis.com/v1beta/interactions"
    private const val API_REVISION = "2026-05-20"
    private const val TTS_MODEL = "gemini-2.5-flash-preview-tts"
    private const val GEN = "https://generativelanguage.googleapis.com/v1beta/models"

    /** The answer spoken, as 24 kHz 16-bit mono PCM, or null. The Fire TV's own TTS is silent, so Gemini speaks.
     *  A deep "Charon" voice with an older, warm tone — the style line steers the delivery, it is not read aloud. */
    fun speech(key: String, text: String, pt: Boolean): ByteArray? = runCatching {
        if (key.isBlank() || text.isBlank()) return null
        val styled = (if (pt) "Fale no tom caloroso e tranquilo de um senhor de idade: "
            else "Speak in the warm, easy tone of an older gentleman: ") + text
        val body = JSONObject()
            .put("contents", JSONArray().put(JSONObject().put(
                "parts", JSONArray().put(JSONObject().put("text", styled)))))
            .put("generationConfig", JSONObject()
                .put("responseModalities", JSONArray().put("AUDIO"))
                .put("speechConfig", JSONObject().put("voiceConfig", JSONObject()
                    .put("prebuiltVoiceConfig", JSONObject().put("voiceName", "Charon")))))
        val conn = (URL("$GEN/$TTS_MODEL:generateContent").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"; doOutput = true; connectTimeout = 10000; readTimeout = 30000
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("x-goog-api-key", key)
        }
        conn.outputStream.use { it.write(body.toString().toByteArray()) }
        if (conn.responseCode !in 200..299) {
            Log.w(TAG, "gemini tts ${conn.responseCode}: ${conn.errorStream?.bufferedReader()?.use { s -> s.readText() }?.take(200)}")
            return null
        }
        val json = conn.inputStream.bufferedReader().use { it.readText() }
        val data = JSONObject(json).getJSONArray("candidates").getJSONObject(0)
            .getJSONObject("content").getJSONArray("parts").getJSONObject(0)
            .getJSONObject("inlineData").getString("data")
        Base64.decode(data, Base64.DEFAULT)
    }.getOrNull()

    private fun task(pt: Boolean) = (if (pt)
        "Você é o assistente de voz de uma TV (o launcher Elimor). O áudio é a fala do usuário. Se a pessoa pedir para " +
            "procurar, achar, abrir ou TOCAR um filme, série, vídeo ou canal do YouTube, responda APENAS com um JSON " +
            "numa linha, nada mais: {\"search\":\"<só o título ou o nome do canal, sem as palavras filme/série/vídeo>\"," +
            "\"type\":\"<movie|series|youtube|any>\",\"what\":\"<latest|history|list>\",\"say\":\"<uma frase curta e " +
            "natural, tipo 'Achei alguns resultados para X'>\"}. Use 'youtube' se ela disser YouTube, vídeo ou o nome " +
            "de um canal ou youtuber (ex.: TED, National Geographic), 'movie' para filme, 'series' para série, senão " +
            "'any'. 'what' só importa no YouTube: 'latest' se ela pedir para abrir/tocar o último ou mais novo vídeo " +
            "de um canal (toca direto), 'history' se perguntar qual foi o último vídeo que ELA assistiu de um canal, " +
            "senão 'list' (mostra os vídeos). Se ela perguntar de JOGOS de futebol ou esporte (ex.: 'hoje tem jogo " +
            "do Barcelona?', 'quais os jogos de hoje?', 'os Lakers jogam hoje?'), responda com o mesmo JSON com " +
            "\"type\":\"games\" e \"search\" = o nome do time como ela disse (Barcelona, Lakers...), ou \"*\" se " +
            "não citar time; \"what\" = 'next' se ela perguntar pelo PRÓXIMO jogo ou pelos próximos jogos, senão " +
            "'today'; a TV sabe a tabela, você não, então deixe \"say\" vazio. Para qualquer outra coisa, responda em " +
            "português, curto e natural, 1 a 3 frases."
    else
        "You are the voice assistant of a TV (the Elimor launcher). The audio is the user speaking. If they ask to " +
            "search, find, open or PLAY a movie, show, video or YouTube channel, reply with ONLY a one-line JSON and " +
            "nothing else: {\"search\":\"<the title or channel name only, no words like movie/show/video>\"," +
            "\"type\":\"<movie|series|youtube|any>\",\"what\":\"<latest|history|list>\",\"say\":\"<one short natural " +
            "line, like 'Here are some results for X'>\"}. Use 'youtube' if they say YouTube, video, or name a channel " +
            "or youtuber (e.g. TED, National Geographic), 'movie' for a film, 'series' for a show, else 'any'. 'what' " +
            "matters only for YouTube: 'latest' if they ask to open/play a channel's latest or newest video (it plays " +
            "right away), 'history' if they ask which video of a channel THEY watched last, else 'list' (shows the " +
            "videos). If they ask about GAMES or sports fixtures (e.g. 'does Barcelona play today?', 'what games are on " +
            "today?', 'do the Lakers play tonight?'), reply with the same JSON with \"type\":\"games\" and \"search\" " +
            "= the team as they said it (Barcelona, Lakers...), or \"*\" if no team is named; \"what\" = 'next' " +
            "if they ask for the NEXT game or the coming games, else 'today'; the TV knows the schedule and you do " +
            "not, so leave \"say\" empty. For anything else, answer in English, short and natural, 1 to 3 sentences.")

    /**
     * The answer text, or a short error string starting with '⚠'. [model] e.g. "gemini-3.6-flash". [grounding] is the
     * live facts Gemini cannot know on its own (the time, the weather), injected so it can answer them.
     */
    fun ask(key: String, model: String, wav: ByteArray, pt: Boolean, grounding: String = ""): String {
        if (key.isBlank()) return "⚠ no key"
        val prompt = if (grounding.isBlank()) task(pt) else task(pt) + "\n\n" + grounding
        val body = JSONObject()
            .put("model", model)
            .put("input", JSONArray()
                .put(JSONObject().put("type", "text").put("text", prompt))
                .put(JSONObject().put("type", "audio")
                    .put("data", Base64.encodeToString(wav, Base64.NO_WRAP))
                    .put("mime_type", "audio/wav")))
        return try {
            val conn = (URL(URL).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                connectTimeout = 10000
                readTimeout = 30000
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("x-goog-api-key", key)
                setRequestProperty("Api-Revision", API_REVISION)
            }
            conn.outputStream.use { it.write(body.toString().toByteArray()) }
            val code = conn.responseCode
            val text = (if (code in 200..299) conn.inputStream else conn.errorStream)
                .bufferedReader().use { it.readText() }
            if (code !in 200..299) {
                Log.w(TAG, "gemini $code: ${text.take(300)}")
                return "⚠ ${firstError(text) ?: "HTTP $code"}"
            }
            answerOf(text) ?: "⚠ no answer"
        } catch (e: Throwable) {
            Log.w(TAG, "gemini call failed: ${e.message}")
            "⚠ ${e.message ?: "network"}"
        }
    }

    /** The text of the model_output step(s) in an Interactions response. */
    private fun answerOf(json: String): String? = runCatching {
        val steps = JSONObject(json).getJSONArray("steps")
        val out = StringBuilder()
        for (i in 0 until steps.length()) {
            val step = steps.getJSONObject(i)
            if (step.optString("type") != "model_output") continue
            val content = step.optJSONArray("content") ?: continue
            for (j in 0 until content.length()) {
                val part = content.getJSONObject(j)
                if (part.optString("type") == "text") out.append(part.optString("text"))
            }
        }
        out.toString().trim().ifEmpty { null }
    }.getOrNull()

    private fun firstError(json: String): String? = runCatching {
        JSONObject(json).getJSONObject("error").getString("message").take(120)
    }.getOrNull()
}
