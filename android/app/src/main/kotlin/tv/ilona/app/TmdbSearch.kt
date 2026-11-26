package tv.ilona.app

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * One search hit to show in the overlay and, on OK, play. [sub] is what the card shows after the title: a TMDB
 * title's year, a video's channel, a game's "Today 21:30". A hit with a [uri] (a YouTube video) opens it in [pkg];
 * one with an [id] (a game) is opened by the Dart side as the home would; the others are TMDB titles, opened by
 * the Dart side by their [tmdbId]. [today]: a game played today (the spoken line says so).
 */
data class SearchHit(
    val title: String,
    val sub: String,
    val posterUrl: String?,
    val tmdbId: Int = 0,
    val isMovie: Boolean = true,
    val uri: String? = null,
    val webUri: String? = null,
    val pkg: String? = null,
    val id: String? = null,
    val today: Boolean = false,
    // A game's two sides, for its card.
    val homeLogo: String? = null,
    val awayLogo: String? = null,
    val homeAbbr: String = "",
    val awayAbbr: String = "",
) {
    /** A game: drawn as the home's game card, not a picture. */
    val isGame get() = id != null
    /** 16:9 (a video's thumb, a game) rather than a 2:3 poster. */
    val isWide get() = uri != null || isGame
}

/**
 * IlonaTv's own movie/series search, from the assistant. Uses TMDB (the key the person set in Settings) so the voice
 * assistant finds the same titles the home rows do. YouTube search is a later step.
 */
object TmdbSearch {
    private const val IMG = "https://image.tmdb.org/t/p/w342"

    /** [type] is "movie", "series" or "any". Up to 12 hits, most relevant first. Falls back to a broad search. */
    fun search(ctx: Context, query: String, type: String): List<SearchHit> {
        val hits = searchOne(ctx, query, type)
        // The wrong type (a series asked as a movie) finds nothing: widen to a multi search before giving up.
        return hits.ifEmpty { if (type == "any") hits else searchOne(ctx, query, "any") }
    }

    private fun searchOne(ctx: Context, query: String, type: String): List<SearchHit> {
        val key = ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.tmdbKey", "").orEmpty()
        if (key.isBlank() || query.isBlank()) return emptyList()
        val path = when (type) { "movie" -> "movie"; "series" -> "tv"; else -> "multi" }
        val lang = if (ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getString("flutter.language", "en") == "pt") "pt-BR" else "en-US"
        val url = "https://api.themoviedb.org/3/search/$path?query=${enc(query)}&include_adult=false" +
            "&language=$lang&api_key=$key"
        return runCatching {
            val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 8000; readTimeout = 8000
            }
            if (conn.responseCode !in 200..299) { Log.w(TAG, "tmdb ${conn.responseCode}"); return emptyList() }
            val json = conn.inputStream.bufferedReader().use { it.readText() }
            val results = JSONObject(json).getJSONArray("results")
            val hits = ArrayList<SearchHit>()
            for (i in 0 until results.length()) {
                val r = results.getJSONObject(i)
                val media = r.optString("media_type", if (path == "tv") "tv" else "movie")
                if (media != "movie" && media != "tv") continue
                val movie = media == "movie"
                val title = if (movie) r.optString("title") else r.optString("name")
                if (title.isBlank()) continue
                val date = if (movie) r.optString("release_date") else r.optString("first_air_date")
                val poster = r.optString("poster_path").takeIf { it.isNotBlank() }
                hits.add(SearchHit(title, date.take(4), poster?.let { IMG + it }, r.optInt("id"), movie))
                if (hits.size >= 12) break
            }
            hits
        }.getOrElse { Log.w(TAG, "tmdb search: ${it.message}"); emptyList() }
    }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")
}
