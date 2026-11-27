package tv.ilona.companion

import android.os.Handler
import android.os.Looper
import dadb.AdbKeyPair
import dadb.AdbShellStream
import dadb.Dadb
import dadb.InstallResult
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

private class Unreachable(cause: Throwable) : IOException(cause)

/** ADB to the TV with dadb, all of it off the main thread; answers go back on the main thread. State is main-thread only. */
class Adb(private val dir: File) {
    private val pool = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var dadb: Dadb? = null
    private var pending: Future<Dadb>? = null
    private var pendingAt = ""
    private var keys: AdbShellStream? = null

    fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "connect" -> connect(call.argument<String>("host")!!, call.argument<Int>("port")!!, result)
            "shell" -> off(result) {
                val r = live().shell(call.argument<String>("cmd")!!)
                mapOf("exitCode" to r.exitCode, "output" to r.allOutput)
            }
            "key" -> off(result) {
                key(call.argument<Int>("code")!!)
                null
            }
            "install" -> off(result) {
                when (val r = live().install(File(call.argument<String>("path")!!))) {
                    InstallResult.Success -> "ok"
                    is InstallResult.Failure -> mapOf("error" to r.reason)
                }
            }
            "close" -> { close(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    fun close() {
        closeKeys()
        drop(pending)
        pending = null
        dadb?.close()
        dadb = null
    }

    // An attempt the TV accepted after its 60 s were up holds an open connection nobody adopted.
    private fun drop(p: Future<Dadb>?) {
        if (p != null && !p.cancel(true)) runCatching { p.get() }.getOrNull()?.takeIf { it !== dadb }?.close()
    }

    private fun connect(host: String, port: Int, result: MethodChannel.Result) {
        val at = "$host:$port"
        // A Retry while the TV still shows the prompt keeps waiting on the same connection, so no second prompt.
        val attempt = pending?.takeIf { pendingAt == at && (!it.isDone || runCatching { it.get() }.isSuccess) }
            ?: pool.submit<Dadb> { open(host, port) }.also { drop(pending); pending = it; pendingAt = at }
        pool.execute {
            val answer: Any = try {
                attempt.get(60, TimeUnit.SECONDS)
            } catch (e: TimeoutException) {
                "unauthorized"
            } catch (e: CancellationException) {
                "unauthorized"
            } catch (e: ExecutionException) {
                if (e.cause is Unreachable) "unreachable" else "unauthorized"
            }
            main.post {
                if (answer is Dadb) {
                    if (pending === attempt) pending = null
                    if (dadb !== answer) {
                        closeKeys()
                        dadb?.close()
                    }
                    dadb = answer
                    result.success("ok")
                } else {
                    result.success(answer)
                }
            }
        }
    }

    private fun open(host: String, port: Int): Dadb {
        // Checked apart so a TV with network debugging off (refused, no route) is told from a prompt not accepted.
        try {
            Socket().use { it.connect(InetSocketAddress(host, port), 5000) }
        } catch (e: IOException) {
            throw Unreachable(e)
        }
        val d = Dadb.create(host, port, keyPair(), connectTimeout = 5000)
        try {
            // Blocks in the handshake until the TV's "Allow debugging?" is answered.
            d.shell("echo ok")
        } catch (e: Throwable) {
            d.close()
            throw e
        }
        if (Thread.interrupted()) {
            d.close()
            throw CancellationException()
        }
        return d
    }

    // In filesDir so the TV's "Always allow" keeps matching this phone across launches.
    @Synchronized
    private fun keyPair(): AdbKeyPair {
        val private = File(dir, "adbkey")
        val public = File(dir, "adbkey.pub")
        if (private.exists() && public.exists()) runCatching { return AdbKeyPair.read(private, public) }
        AdbKeyPair.generate(private, public)
        return AdbKeyPair.read(private, public)
    }

    // One shell for every key: no stream to open per press. Its output is dropped so nothing waits on a reader.
    @Synchronized
    private fun key(code: Int) {
        try {
            val shell = keys ?: live().openShell("sh").also {
                it.write("exec >/dev/null 2>&1\n")
                keys = it
            }
            shell.write("input keyevent $code\n")
        } catch (e: Throwable) {
            closeKeys()
            throw e
        }
    }

    @Synchronized
    private fun closeKeys() {
        runCatching { keys?.close() }
        keys = null
    }

    private fun live() = dadb ?: throw IOException("not connected")

    private fun off(result: MethodChannel.Result, work: () -> Any?) {
        pool.execute {
            val r = runCatching(work)
            main.post { r.fold({ result.success(it) }, { result.error("adb", it.message ?: it.toString(), null) }) }
        }
    }
}
