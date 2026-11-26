package tv.ilona.app

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.animation.ValueAnimator
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.SystemClock
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.SweepGradient
import android.graphics.drawable.GradientDrawable
import android.widget.HorizontalScrollView
import android.widget.ImageView
import java.net.URL
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The voice assistant as an accessibility overlay: it draws above every app and above Alexa's own chrome, so the app
 * behind keeps playing. One [accent] colour builds the whole gradient (orb and text), set from IlonaTv's settings. The
 * mic-button bounce shows it (HomeWatcher.onAlexa); Back or a lull hides it. Main thread only.
 */
object Assistant {
    private var root: View? = null
    private var meter: MicMeter? = null
    private var track: AudioTrack? = null
    private var audio: AudioManager? = null
    private var focus: AudioFocusRequest? = null
    private var processing = false  // a question is being answered: don't restart listening on a held redraw
    private var shownAt = 0L        // when an answer/result went on screen: a late Alexa echo must not relisten over it
    private const val RELISTEN_LOCK_MS = 3500L
    private val handler = Handler(Looper.getMainLooper())

    /** Silences everything else (video pauses) for the whole interaction, so the mic hears the person and the spoken
     *  answer is clear; released when the overlay goes. */
    private fun grabAudio(ctx: Context) {
        if (focus != null) return
        audio = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANT)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .build()
            .also { audio?.requestAudioFocus(it) }
    }

    private fun freeAudio() {
        focus?.let { audio?.abandonAudioFocusRequest(it) }; focus = null
    }

    val isUp get() = root != null

    fun show(service: AccessibilityService, accent: Int, fresh: Boolean = false) {
        // Already up. Echo bounces (held, or Alexa re-showing) keep what is on screen. Only a real new press [fresh]
        // starts a new question: back to listening.
        (root as? Scrim)?.let { scrim ->
            if (scrim.accent != accent) scrim.recolour(accent)
            // A real new press: not while an answer is still coming, and not within a few seconds of one that just
            // showed (both are Alexa's late echoes, not the person pressing again).
            if (fresh && !processing && SystemClock.uptimeMillis() - shownAt > RELISTEN_LOCK_MS) {
                processing = false
                meter?.stop()
                scrim.relisten()
                meter = MicMeter(service, scrim.orbView) { wav -> onUtterance(service, wav) }.also { it.start() }
            }
            armAutoHide()
            return
        }
        val scrim = Scrim(service, accent)
        val wm = service.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
            PixelFormat.TRANSLUCENT,
        )
        runCatching { wm.addView(scrim, lp) }.onFailure {
            Log.w(TAG, "assistant overlay failed: ${it.message}"); return
        }
        root = scrim
        grabAudio(service)
        meter = MicMeter(service, scrim.orbView) { wav -> onUtterance(service, wav) }.also { it.start() }
        armAutoHide()
    }

    /** The person stopped talking: send the clip to Gemini, then show and speak the answer. */
    private fun onUtterance(ctx: Context, wav: ByteArray) {
        val scrim = root as? Scrim ?: return
        val pt = lang(ctx) == "pt"
        // Less than ~0.3 s of speech: nothing useful was said.
        if (wav.size < 44 + 16000 * 2 * 3 / 10) {
            scrim.answer(if (pt) "Não ouvi. Tente de novo." else "I didn't catch that.")
            armAutoHide()
            return
        }
        // Listening is over: the user released, so Alexa is about to answer — cancel her again here, release the mic.
        runCatching { ctx.sendBroadcast(Intent("amazon.speech.RESET_INTERACTIONS")) }
        meter?.stop(); meter = null
        processing = true
        scrim.thinking(pt)
        armAutoHide() // thinking + reading the answer takes a while
        val key = ctx.geminiKey()
        Thread {
            val grounding = Grounding.now(ctx, pt) // time + weather, so Gemini can answer them
            val answer = GeminiAssistant.ask(key, ctx.geminiModel(), wav, pt, grounding)
            Log.i(TAG, "assistant answer: ${answer.take(200)}")
            // A search/play request comes back as {"search":...,"type":...,"say":...}: show a spoken line and the hits.
            val search = parseSearch(answer)
            if (search != null) {
                // Main thread. Shows [hits] under [title] with the [say] line, or plays the first for "latest".
                val showHits = { hits: List<SearchHit>, title: String, say: String ->
                    Log.i(TAG, "assistant search '${search.query}' (${search.type}/${search.what}): ${hits.size} hits")
                    processing = false
                    shownAt = SystemClock.uptimeMillis()
                    // "Open the latest video of X": the first hit plays at once, nothing to pick.
                    if (search.what == "latest" && hits.isNotEmpty()) play(ctx, hits[0])
                    else (root as? Scrim)?.let { it.results(ctx, title, say, hits); armAutoHide() }
                }
                val noEngine = {
                    processing = false
                    (root as? Scrim)?.answer(if (pt) "Abre o IlonaTv primeiro." else "Open IlonaTv first.")
                    armAutoHide()
                }
                when (search.type) {
                    // YouTube lives on the Dart side (signed-in search, the histories): ask it over the channel.
                    "youtube" -> HostChannel.assistantSearch("youtube", search.query, search.what) { hits ->
                        if (hits == null) noEngine() else showHits(hits, search.query, search.say)
                    }
                    // Games too (the home's ESPN rows). Gemini cannot know the fixtures, so the spoken line is
                    // written here from what came back and Gemini's "say" is dropped.
                    "games" -> HostChannel.assistantSearch("games", search.query, search.what) { hits ->
                        if (hits == null) return@assistantSearch noEngine()
                        val team = search.query.takeIf { it != "*" }
                        val next = search.what == "next"
                        val say = gamesLine(pt, team, next, hits)
                        val title = team ?: if (next) (if (pt) "Próximos jogos" else "Coming games")
                            else (if (pt) "Jogos de hoje" else "Today's games")
                        showHits(hits, title, say)
                        Thread { GeminiAssistant.speech(key, say, pt)?.let { play(it) } }.start()
                    }
                    else -> {
                        val hits = TmdbSearch.search(ctx, search.query, search.type)
                        handler.post { showHits(hits, search.query, search.say) }
                    }
                }
                if (search.type != "games" && search.say.isNotBlank())
                    GeminiAssistant.speech(key, search.say, pt)?.let { play(it) }
                return@Thread
            }
            handler.post {
                processing = false
                shownAt = SystemClock.uptimeMillis()
                (root as? Scrim)?.let { it.answer(answer); armAutoHide() }
            }
            // The Fire TV's own TTS is silent, so Gemini speaks the answer and we play the PCM.
            if (!answer.startsWith("⚠")) GeminiAssistant.speech(key, answer, pt)?.let { play(it) }
        }.start()
    }

    /** Debug builds (AssistantPreview): the overlay with [hits] under [title], no microphone involved. */
    fun preview(service: AccessibilityService, title: String, say: String, hits: List<SearchHit>) {
        show(service, service.assistantColor())
        meter?.stop(); meter = null
        processing = false
        (root as? Scrim)?.results(service, title, say, hits)
        armAutoHide()
    }

    /** The search-results row (if any) is taking the D-pad. */
    val hasResults get() = (root as? Scrim)?.hasResults == true
    fun moveResults(dir: Int) { (root as? Scrim)?.move(dir); armAutoHide() }

    /** OK on a result: open it and close the overlay. */
    fun playSelected(ctx: Context) {
        val hit = (root as? Scrim)?.selected() ?: return
        armAutoHide()
        play(ctx, hit)
    }

    /**
     * What to say about the games that came back for [team] (null: everyone's), asked for today or the [next] ones.
     * "Yes! Home × Away, today 21:30", "Not today. The next is ...", "No games today", "3 games today",
     * "The next game is ...".
     */
    private fun gamesLine(pt: Boolean, team: String?, next: Boolean, hits: List<SearchHit>): String {
        val first = hits.firstOrNull()
        val n = hits.size
        return when {
            first == null && team == null -> if (pt) (if (next) "Não achei jogos por vir." else "Sem jogos hoje.")
                else (if (next) "I found no coming games." else "No games today.")
            first == null -> if (pt) "Não achei jogo do $team." else "I found no $team game."
            next && team != null -> if (pt) "O próximo jogo do $team é ${first.title}, ${first.sub.lowercase()}."
                else "The next $team game is ${first.title}, ${first.sub.lowercase()}."
            next -> if (pt) "Tem $n ${if (n == 1) "jogo" else "jogos"} por vir. O primeiro: ${first.title}, ${first.sub.lowercase()}."
                else "$n coming ${if (n == 1) "game" else "games"}. First: ${first.title}, ${first.sub.lowercase()}."
            team == null -> if (pt) "Hoje tem $n ${if (n == 1) "jogo" else "jogos"}."
                else "$n ${if (n == 1) "game" else "games"} today."
            first.today -> if (pt) "Sim! ${first.title}, ${first.sub.lowercase()}."
                else "Yes! ${first.title}, ${first.sub.lowercase()}."
            else -> if (pt) "Hoje não. O próximo é ${first.title}, ${first.sub.lowercase()}."
                else "Not today. The next is ${first.title}, ${first.sub.lowercase()}."
        }
    }

    /**
     * Opens [hit]: a video in its app by uri; a game or a TMDB title through the Dart side, as the home does, so it
     * opens where Settings says.
     */
    private fun play(ctx: Context, hit: SearchHit) {
        if (hit.uri != null) {
            hide("played")
            if (!HostChannel.open(ctx, hit)) Log.w(TAG, "assistant play: nothing opened ${hit.uri}")
            return
        }
        if (!HostChannel.hasEngine) {
            (root as? Scrim)?.answer(if (lang(ctx) == "pt") "Abre o IlonaTv primeiro." else "Open IlonaTv first.")
            armAutoHide()
            return
        }
        if (hit.id != null) {
            hide("played")
            HostChannel.assistantOpen("games", hit.id)
            return
        }
        hide("played")
        HostChannel.assistantOpen(if (hit.isMovie) "movie" else "series", hit.tmdbId.toString())
    }

    /** A search/play answer: what to look for, where, how, and the line to speak. */
    private class Search(val query: String, val type: String, val what: String, val say: String)

    /** The {"search":...,"type":...,"what":...,"say":...} of a search/play answer, or null for a plain one. */
    private fun parseSearch(answer: String): Search? = runCatching {
        val s = answer.trim().removePrefix("```json").removePrefix("```").removeSuffix("```").trim()
        if (!s.startsWith("{") || !s.contains("\"search\"")) return null
        val o = org.json.JSONObject(s)
        val q = o.optString("search").trim()
        if (q.isEmpty()) null
        else Search(q, o.optString("type", "any").ifBlank { "any" }, o.optString("what", "list").ifBlank { "list" },
            o.optString("say").trim())
    }.getOrNull()

    /** Plays 24 kHz 16-bit mono PCM (Gemini's spoken answer) through the TV speakers, a touch louder. Blocks. */
    private fun play(pcm: ByteArray) {
        // Lift the volume ~1.5x with clipping, so it carries across the room.
        val b = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN)
        var i = 0
        while (i + 1 < pcm.size) {
            val s = (b.getShort(i) * 1.5f).toInt().coerceIn(-32768, 32767)
            b.putShort(i, s.toShort()); i += 2
        }
        val rate = 24000
        val min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val t = runCatching {
            AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setBufferSizeInBytes(maxOf(min, pcm.size))
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
        }.getOrNull() ?: return
        track?.runCatching { release() }
        track = t
        t.write(pcm, 0, pcm.size)
        t.play()
        armAutoHide() // the answer is being spoken; keep the overlay up
        Thread.sleep(pcm.size.toLong() / (rate * 2) * 1000 + 500)
        runCatching { if (track === t) { t.stop(); t.release(); track = null } }
    }

    /** A safety limit only: the overlay normally goes on Back or Home. Each show/state change pushes it out. */
    private fun armAutoHide() {
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ hide("timeout") }, 15000L)
    }

    fun hide(why: String) {
        handler.removeCallbacksAndMessages(null)
        processing = false
        meter?.stop()
        meter = null
        track?.runCatching { stop(); release() }; track = null
        freeAudio()
        val v = root ?: return
        root = null
        (v as? Scrim)?.stop()
        val wm = v.context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        runCatching { wm.removeView(v) }
        Log.i(TAG, "assistant hidden ($why)")
    }

    private fun lang(ctx: Context): String =
        ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.language", "en") ?: "en"

    /** The full-screen scrim with the orb, the status line and the answer. */
    private class Scrim(ctx: Context, var accent: Int) : FrameLayout(ctx) {
        private val pt = lang(ctx) == "pt"
        private val orb = OrbView(ctx, accent)
        val orbView get() = orb
        private val status = TextView(ctx).apply {
            text = if (pt) "Ouvindo…" else "Listening…"
            setTextColor(0x99FFFFFF.toInt())
            textSize = 22f
        }
        private val answer = TextView(ctx).apply {
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 30f
            visibility = GONE
        }
        // Match IlonaTv's content row: card = 0.092 of the screen wide, 2:3, gap 0.014, left pad 0.04.
        private val screenW = resources.displayMetrics.widthPixels
        private val cardW = (screenW * 0.092f).toInt()
        private val cardH = cardW * 3 / 2
        private val gap = (screenW * 0.014f).toInt()
        private val sidePad = (screenW * 0.04f).toInt()
        private val radius = cardW * 0.09f

        private val topRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            clipChildren = false; clipToPadding = false
            val s = dp(132)
            addView(orb, LayoutParams(s, s))
            addView(status, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
                .apply { marginStart = dp(20) })
        }
        private val header = TextView(ctx).apply {
            setTextColor(0xE6FFFFFF.toInt()); setTextSize(TypedValue.COMPLEX_UNIT_PX, cardW * 0.18f)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(sidePad, dp(28), 0, 0)
            visibility = GONE
        }
        // One grid with the home and the text above: cards start at sidePad like the header. tvOS keeps 60 px of
        // 1080 clear at the bottom, so the cards never sit on the screen's edge.
        private val resultsRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(sidePad, dp(18), sidePad, (screenW * 0.031f).toInt())
            clipChildren = false; clipToPadding = false
        }
        private val resultsScroll = HorizontalScrollView(ctx).apply {
            isHorizontalScrollBarEnabled = false
            clipChildren = false; clipToPadding = false
            visibility = GONE
            addView(resultsRow)
        }
        private var hits: List<SearchHit> = emptyList()
        private val cards = mutableListOf<View>()
        private var sel = 0

        private val col = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            clipChildren = false
            addView(topRow, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
                .apply { leftMargin = sidePad })
            addView(answer, LayoutParams(dp(680), LayoutParams.WRAP_CONTENT)
                .apply { topMargin = dp(28); leftMargin = sidePad })
            addView(header, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
            addView(resultsScroll, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        }

        init {
            setBackgroundColor(0xF2000000.toInt())
            clipChildren = false; clipToPadding = false
            addView(col, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
            position(centered = false)
        }

        /** Listening/thinking/answer sit top-left; a search row centres vertically like a home row. */
        private fun position(centered: Boolean) {
            (col.layoutParams as LayoutParams).apply {
                gravity = if (centered) Gravity.CENTER_VERTICAL else (Gravity.TOP or Gravity.START)
                topMargin = if (centered) 0 else dp(56)
            }
            col.requestLayout()
        }

        /** Keep the usual answer (orb + spoken line) at the top, with the result row below it. */
        fun results(ctx: Context, query: String, say: String, list: List<SearchHit>) {
            topRow.visibility = VISIBLE
            status.text = "IlonaTv"
            answer.text = say.ifBlank { query }
            answer.visibility = VISIBLE
            position(centered = false)
            hits = list
            cards.clear(); resultsRow.removeAllViews()
            if (list.isEmpty()) {
                if (say.isBlank()) answer.text = if (pt) "Nada encontrado." else "Nothing found."
                header.visibility = GONE
                resultsScroll.visibility = GONE
                return
            }
            header.text = query
            header.visibility = VISIBLE
            for (h in list) { val c = card(ctx, h); cards.add(c); resultsRow.addView(c) }
            sel = 0; highlight()
            resultsScroll.visibility = VISIBLE
        }

        val hasResults get() = hits.isNotEmpty()
        fun selected(): SearchHit? = hits.getOrNull(sel)

        fun move(dir: Int) {
            if (hits.isEmpty()) return
            sel = (sel + dir).coerceIn(0, hits.size - 1)
            highlight()
            cards.getOrNull(sel)?.let {
                resultsScroll.smoothScrollTo((it.left - sidePad).coerceAtLeast(0), 0)
            }
        }

        /** The selected card grows, lifts and gets a white rim (drawn over its picture); the others dim. */
        private fun highlight() {
            cards.forEachIndexed { i, c ->
                val on = i == sel
                c.animate().scaleX(if (on) 1.12f else 1f).scaleY(if (on) 1.12f else 1f)
                    .alpha(if (on) 1f else 0.5f).setDuration(120).start()
                c.translationZ = if (on) dp(8).toFloat() else 0f
                (c as ViewGroup).getChildAt(0).foreground = if (!on) null else GradientDrawable().apply {
                    cornerRadius = radius
                    setColor(Color.TRANSPARENT)
                    setStroke((cardW * 0.045f).toInt(), Color.WHITE)
                }
            }
        }

        /** Wide cards (a video's thumb, a game) are 16:9 at the home's wide width; posters 2:3. */
        private val wideW = (screenW * 0.155f).toInt()
        private val wideH = wideW * 9 / 16

        /**
         * A card: its face (poster, thumb or game) and, under it, the title and a dimmer second line. Android TV's
         * card guide: 16:9 for video, 2:3 for posters; text on an image over a dark gradient. A face with no
         * picture is a dark gradient with the title (poster) or a play mark (video) on it, not a grey box.
         */
        private fun card(ctx: Context, h: SearchHit): View {
            val w = if (h.isWide) wideW else cardW
            val face = when {
                h.isGame -> gameFace(ctx, h)
                else -> pictureFace(ctx, h, w, if (h.isWide) wideH else cardH)
            }
            val title = TextView(ctx).apply {
                text = h.title
                setTextColor(0xE6FFFFFF.toInt()); setTextSize(TypedValue.COMPLEX_UNIT_PX, cardW * 0.11f)
                maxLines = if (h.isGame) 1 else 2; ellipsize = android.text.TextUtils.TruncateAt.END
                layoutParams = LinearLayout.LayoutParams(w, LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) }
            }
            val sub = TextView(ctx).apply {
                text = h.sub
                setTextColor(0x99FFFFFF.toInt()); setTextSize(TypedValue.COMPLEX_UNIT_PX, cardW * 0.095f)
                maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
                visibility = if (h.sub.isBlank() || h.isGame) GONE else VISIBLE
                layoutParams = LinearLayout.LayoutParams(w, LayoutParams.WRAP_CONTENT).apply { topMargin = dp(2) }
            }
            return LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                clipChildren = false; clipToPadding = false
                layoutParams = LinearLayout.LayoutParams(w, LayoutParams.WRAP_CONTENT).apply { marginEnd = gap }
                addView(face); addView(title); addView(sub)
            }
        }

        private fun rounded(v: View) {
            v.clipToOutline = true
            v.outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(view: View, o: android.graphics.Outline) =
                    o.setRoundRect(0, 0, view.width, view.height, radius)
            }
        }

        private fun faceBackground() = GradientDrawable(
            GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(0xFF3A3A46.toInt(), 0xFF15151A.toInt()),
        ).apply { cornerRadius = radius }

        /** A poster or thumb: the picture when it loads, until then (or without one) the title or a play mark. */
        private fun pictureFace(ctx: Context, h: SearchHit, w: Int, hgt: Int): View {
            val picture = ImageView(ctx).apply { scaleType = ImageView.ScaleType.CENTER_CROP }
            val stand = TextView(ctx).apply {
                gravity = Gravity.CENTER
                if (h.isWide) {
                    text = "▶"; setTextColor(0x66FFFFFF); setTextSize(TypedValue.COMPLEX_UNIT_PX, hgt * 0.34f)
                } else {
                    text = h.title; setTextColor(0xCCFFFFFF.toInt()); setTextSize(TypedValue.COMPLEX_UNIT_PX, w * 0.12f)
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    maxLines = 4; ellipsize = android.text.TextUtils.TruncateAt.END
                    setPadding(dp(10), dp(10), dp(10), dp(10))
                }
            }
            return FrameLayout(ctx).apply {
                layoutParams = LinearLayout.LayoutParams(w, hgt)
                background = faceBackground()
                rounded(this)
                addView(picture, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
                addView(stand, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
                h.posterUrl?.let { loadPicture(it, picture) { stand.visibility = GONE } }
            }
        }

        /** A game as the home draws it: the two crests with a × between, their abbreviations, the time or score. */
        private fun gameFace(ctx: Context, h: SearchHit): View {
            fun side(logo: String?, abbr: String) = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL
                val crest = ImageView(ctx).apply { scaleType = ImageView.ScaleType.FIT_CENTER }
                val s = (wideH * 0.42f).toInt()
                addView(crest, LinearLayout.LayoutParams(s, s))
                addView(TextView(ctx).apply {
                    text = abbr; setTextColor(0xE6FFFFFF.toInt())
                    setTextSize(TypedValue.COMPLEX_UNIT_PX, wideH * 0.13f)
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                }, LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
                    .apply { topMargin = dp(4) })
                logo?.let { loadPicture(it, crest) {} }
            }
            val sides = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER
                addView(side(h.homeLogo, h.homeAbbr), LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
                addView(TextView(ctx).apply {
                    text = "×"; setTextColor(0x99FFFFFF.toInt())
                    setTextSize(TypedValue.COMPLEX_UNIT_PX, wideH * 0.14f)
                })
                addView(side(h.awayLogo, h.awayAbbr), LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            }
            val status = TextView(ctx).apply {
                text = h.sub; gravity = Gravity.CENTER
                setTextColor(0xB3FFFFFF.toInt()); setTextSize(TypedValue.COMPLEX_UNIT_PX, wideH * 0.11f)
            }
            return LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(wideW, wideH)
                background = faceBackground()
                rounded(this)
                setPadding(dp(10), dp(8), dp(10), dp(8))
                addView(sides, LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
                addView(status, LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
            }
        }

        /** Fetches [url] off the main thread into [into]; [loaded] runs on the main thread once it is in. */
        private fun loadPicture(url: String, into: ImageView, loaded: () -> Unit) {
            Thread {
                val bmp = runCatching {
                    (URL(url).openConnection() as java.net.HttpURLConnection).apply {
                        connectTimeout = 8000; readTimeout = 8000
                    }.inputStream.use { BitmapFactory.decodeStream(it) }
                }.getOrNull() ?: return@Thread
                into.post { into.setImageBitmap(bmp); loaded() }
            }.start()
        }

        fun thinking(pt: Boolean) { status.text = if (pt) "Pensando…" else "Thinking…"; orb.setLevel(0f) }

        /** Back to listening for a follow-up question. */
        fun relisten() {
            topRow.visibility = VISIBLE
            status.text = if (pt) "Ouvindo…" else "Listening…"
            answer.visibility = GONE
            header.visibility = GONE
            resultsScroll.visibility = GONE
            hits = emptyList(); cards.clear(); resultsRow.removeAllViews()
            position(centered = false)
        }

        fun answer(text: String) {
            status.text = "IlonaTv"
            answer.text = text
            answer.visibility = VISIBLE
        }

        fun recolour(c: Int) { accent = c; orb.recolour(c) }
        fun stop() = orb.stop()
        private fun dp(v: Int) = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics,
        ).toInt()
    }

    /** A circle filled with a sweeping [accent] gradient, a soft glow behind it, breathing. */
    private class OrbView(ctx: Context, accent: Int) : View(ctx) {
        private var stops = gradient(accent)
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        private val glow = Paint(Paint.ANTI_ALIAS_FLAG)
        private val matrix = Matrix()
        private var angle = 0f
        private var pulse = 0f

        private val spin = ValueAnimator.ofFloat(0f, 360f).apply {
            duration = 6000; repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener { angle = it.animatedValue as Float; postInvalidateOnAnimation() }
            start()
        }
        private val breathe = ValueAnimator.ofFloat(0f, 1f, 0f).apply {
            duration = 1600; repeatCount = ValueAnimator.INFINITE
            addUpdateListener { pulse = it.animatedValue as Float }
            start()
        }

        /** Live mic loudness 0..1, smoothed; makes the orb swell and brighten as the person speaks. */
        private var level = 0f
        fun setLevel(l: Float) { level = level * 0.6f + l * 0.4f; postInvalidateOnAnimation() }

        fun recolour(accent: Int) { stops = gradient(accent); invalidate() }
        fun stop() { spin.cancel(); breathe.cancel() }

        override fun onDraw(canvas: Canvas) {
            val cx = width / 2f; val cy = height / 2f
            val maxR = minOf(width, height) / 2f
            val r = maxR * (0.52f + pulse * 0.04f + level * 0.22f)
            // The glow fades to nothing by the view's edge, so it never clips into a square.
            glow.shader = RadialGradient(
                cx, cy, maxR,
                intArrayOf(withAlpha(stops[1], 0.55f), withAlpha(stops[1], 0f)),
                floatArrayOf(r / maxR * 0.7f, 1f), Shader.TileMode.CLAMP,
            )
            canvas.drawCircle(cx, cy, maxR, glow)
            matrix.setRotate(angle, cx, cy)
            fill.shader = SweepGradient(cx, cy, stops + stops[0], null).apply { setLocalMatrix(matrix) }
            canvas.drawCircle(cx, cy, r, fill)
        }
    }

    /**
     * Records the TV's microphone while the overlay is up, reporting loudness (0..1) to the orb, until a pause
     * after speech or [MAX_MS]. The clip is kept in memory only and handed to [onUtterance], which sends it to Gemini
     * with the user's own key; nothing is written to storage. Needs RECORD_AUDIO; without it the orb just breathes.
     */
    private class MicMeter(
        private val ctx: Context,
        private val orb: OrbView,
        private val onUtterance: (ByteArray) -> Unit,
    ) {
        private var rec: AudioRecord? = null
        @Volatile private var running = false
        private var thread: Thread? = null
        private val main = Handler(Looper.getMainLooper())

        fun start() {
            if (ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                Log.w(TAG, "assistant mic: no RECORD_AUDIO permission"); return
            }
            val rate = 16000
            val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            val r = try {
                @Suppress("MissingPermission")
                AudioRecord(
                    MediaRecorder.AudioSource.VOICE_RECOGNITION, rate,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, rate),
                )
            } catch (e: Throwable) { Log.w(TAG, "assistant mic: ${e.message}"); return }
            if (r.state != AudioRecord.STATE_INITIALIZED) {
                Log.w(TAG, "assistant mic: not initialized"); r.release(); return
            }
            rec = r; running = true
            r.startRecording()
            Log.i(TAG, "assistant mic: on, routed=${r.routedDevice?.productName} type=${r.routedDevice?.type}")
            thread = Thread {
                val pcm = ByteArrayOutputStream()
                val buf = ShortArray(rate / 10) // 100 ms frames
                val startMs = SystemClock.uptimeMillis()
                var lastSpeechMs = 0L  // 0 = no speech heard yet
                var logAt = 0L
                while (running) {
                    // Non-blocking: when the mic is starved (Alexa contends), read returns 0 and we still check for
                    // the end of the phrase on the wall clock instead of blocking.
                    val n = r.read(buf, 0, buf.size, AudioRecord.READ_NON_BLOCKING)
                    val now = SystemClock.uptimeMillis()
                    if (n <= 0) Thread.sleep(20)
                    if (n > 0) {
                        var sum = 0.0
                        for (i in 0 until n) { val v = buf[i].toInt(); sum += v.toDouble() * v }
                        val rms = Math.sqrt(sum / n)
                        val level = ((rms - 200.0) / 9000.0).coerceIn(0.0, 1.0).toFloat()
                        main.post { orb.setLevel(level) }
                        if (rms > SPEAK_RMS) lastSpeechMs = now
                        // Keep every frame from the start: the mic can starve (Alexa contends) right after speech
                        // begins, so accumulating only post-speech loses it. Gemini ignores the leading quiet.
                        // The couch is far and the built-in mic is quiet, so boost the clip.
                        val bytes = ByteBuffer.allocate(n * 2).order(ByteOrder.LITTLE_ENDIAN)
                        for (i in 0 until n) bytes.putShort((buf[i] * GAIN).toInt().coerceIn(-32768, 32767).toShort())
                        pcm.write(bytes.array())
                        if (now - logAt > 500) { logAt = now; Log.i(TAG, "assistant mic n=$n rms=${rms.toInt()} heard=${lastSpeechMs > 0}") }
                    }
                    val heard = lastSpeechMs > 0L
                    // End of phrase: a pause after speech, or the wall-clock safety cap (robust to read stalls).
                    if ((heard && now - lastSpeechMs >= END_SILENCE_MS) || now - startMs >= MAX_MS) {
                        running = false
                        val wav = wav(pcm.toByteArray(), rate)
                        Log.i(TAG, "assistant utterance: ${pcm.size()} pcm bytes, heard=$heard")
                        main.post { onUtterance(wav) }
                    }
                }
                runCatching { r.stop() }
            }.apply { start() }
        }

        fun stop() {
            running = false
            thread?.join(200); thread = null
            rec?.let { runCatching { it.stop() }; it.release() }; rec = null
        }

        private companion object {
            const val SPEAK_RMS = 600.0   // above the ducked-room floor (~100-230 measured)
            const val END_SILENCE_MS = 1100L
            const val MAX_MS = 10000L
            const val GAIN = 4f           // the couch is far and the built-in mic is quiet
        }
    }

    /** 16-bit mono PCM at [rate] wrapped in a WAV container, for Gemini's audio/wav input. */
    private fun wav(pcm: ByteArray, rate: Int): ByteArray {
        val h = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        h.put("RIFF".toByteArray()).putInt(36 + pcm.size).put("WAVE".toByteArray())
        h.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
        h.putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
        h.put("data".toByteArray()).putInt(pcm.size)
        return h.array() + pcm
    }

    /** Three stops around the wheel from [accent], as in the Flutter design. */
    private fun gradient(accent: Int): IntArray {
        val hsv = FloatArray(3); Color.colorToHSV(accent, hsv)
        fun at(dh: Float, s: Float, v: Float) =
            Color.HSVToColor(floatArrayOf((hsv[0] + dh + 360f) % 360f, s, v))
        return intArrayOf(at(-36f, 0.9f, 0.95f), accent, at(42f, 0.85f, 1f), at(80f, 0.8f, 0.95f))
    }

    private fun withAlpha(c: Int, a: Float) =
        Color.argb((a * 255).toInt(), Color.red(c), Color.green(c), Color.blue(c))
}
