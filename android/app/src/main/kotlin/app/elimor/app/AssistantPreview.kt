package app.elimor.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Debug builds only (HomeWatcher registers it at run time in a debuggable build): opens the assistant overlay with
 * canned results of one kind, so its cards can be looked at on the emulator without a microphone.
 *
 *   adb shell am broadcast -a app.elimor.ASSIST_PREVIEW --es kind posters|videos|games
 */
object AssistantPreview : BroadcastReceiver() {
    const val ACTION = "app.elimor.ASSIST_PREVIEW"

    private const val TMDB = "https://image.tmdb.org/t/p/w342"
    private const val YT = "https://i.ytimg.com/vi"
    private const val ESPN = "https://a.espncdn.com/i/teamlogos"

    override fun onReceive(ctx: Context, intent: Intent) {
        Log.i(TAG, "assistant preview: ${intent.getStringExtra("kind")} (service ${HomeWatcher.instance != null})")
        val service = HomeWatcher.instance ?: return
        val (title, say, hits) = when (intent.getStringExtra("kind")) {
            "videos" -> Triple("Sample Channel", "Here are some videos from Sample Channel.", listOf(
                SearchHit("A Review of a Very Big Monitor", "Sample Channel", "$YT/dQw4w9WgXcQ/hqdefault.jpg",
                    uri = "vnd.youtube://dQw4w9WgXcQ"),
                SearchHit("The Fastest PC We Have Ever Built – A Very Long Title That Wraps", "Sample Channel",
                    "$YT/9bZkp7q19f0/hqdefault.jpg", uri = "vnd.youtube://9bZkp7q19f0"),
                SearchHit("A video with no thumbnail", "Sample Channel", null, uri = "vnd.youtube://x"),
                SearchHit("Short one", "Sample Clips", "$YT/kJQP7kiw5Fk/hqdefault.jpg", uri = "vnd.youtube://kJQP7kiw5Fk"),
            ))
            "games" -> Triple("Games today", "There are 3 games today.", listOf(
                SearchHit("Home Team × Away Team", "Today 21:30", null, id = "espn:1",
                    homeAbbr = "HOM", awayAbbr = "AWY"),
                SearchHit("Celtics × Grizzlies", "LIVE · 54–61 · Q3", null, id = "espn:2",
                    homeLogo = "$ESPN/nba/500/bos.png", awayLogo = "$ESPN/nba/500/mem.png",
                    homeAbbr = "BOS", awayAbbr = "MEM"),
                SearchHit("Rangers × Avalanche", "Tomorrow 19:00", null, id = "espn:3",
                    homeLogo = "$ESPN/nhl/500/nyr.png", awayLogo = "$ESPN/nhl/500/col.png",
                    homeAbbr = "NYR", awayAbbr = "COL"),
            ))
            else -> Triple("Harry Potter", "Here are some results for Harry Potter.", listOf(
                SearchHit("Harry Potter and the Philosopher's Stone", "2001", "$TMDB/wuMc08IPKEatf9rnMNXvIDxqP4W.jpg", 671),
                SearchHit("Harry Potter and the Chamber of Secrets", "2002", "$TMDB/sdEOH0992YZ0QSxgXNIGLq1ToUi.jpg", 672),
                SearchHit("A Title With No Poster At All", "2026", null, 1),
                SearchHit("Harry Potter and the Prisoner of Azkaban", "2004", "$TMDB/aWxwnYoe8p2d2fcxOqtvAtJ72Rw.jpg", 673),
                SearchHit("Harry Potter and the Goblet of Fire", "2005", "$TMDB/fECBtHlr0RB3foNHDiCBXeg9Bv9.jpg", 674),
            ))
        }
        Assistant.preview(service, title, say, hits)
    }
}
