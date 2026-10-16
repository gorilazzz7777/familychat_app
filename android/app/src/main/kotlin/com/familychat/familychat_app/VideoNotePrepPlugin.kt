package com.familychat.familychat_app

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.otaliastudios.transcoder.Transcoder
import com.otaliastudios.transcoder.TranscoderListener
import com.otaliastudios.transcoder.source.UriDataSource
import com.otaliastudios.transcoder.strategy.DefaultAudioStrategy
import com.otaliastudios.transcoder.strategy.DefaultVideoStrategy
import com.otaliastudios.transcoder.resize.AspectRatioResizer
import com.otaliastudios.transcoder.resize.AtMostResizer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Future

/**
 * Center-crop camera videos to a square ≤[maxSide] for TDLib video notes.
 * Non-square mp4 → TDLib error 400.
 */
class VideoNotePrepPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "VideoNotePrep"
        private const val CHANNEL = "com.familychat/video_note_prep"
        private const val DEFAULT_MAX_SIDE = 384
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var job: Future<Void>? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        job?.cancel(true)
        job = null
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareSquare" -> {
                val path = call.argument<String>("path")
                val maxSide = call.argument<Int>("maxSide") ?: DEFAULT_MAX_SIDE
                if (path.isNullOrBlank()) {
                    result.error("bad_args", "path required", null)
                    return
                }
                prepareSquare(path, maxSide.coerceIn(96, 640), result)
            }
            else -> result.notImplemented()
        }
    }

    private fun prepareSquare(path: String, maxSide: Int, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("no_context", "plugin not attached", null)
            return
        }
        val input = File(path)
        if (!input.exists() || input.length() <= 0L) {
            result.error("missing", "file not found: $path", null)
            return
        }

        val (w, h) = readSize(path)
        if (w > 0 && h > 0 && w == h && w <= maxSide) {
            result.success(
                mapOf(
                    "path" to path,
                    "length" to w,
                    "converted" to false,
                ),
            )
            return
        }

        val outDir = File(ctx.cacheDir, "video_notes").apply { mkdirs() }
        val out = File(outDir, "vn_${System.currentTimeMillis()}.mp4")
        val strategy = DefaultVideoStrategy.Builder()
            .addResizer(AspectRatioResizer(1f))
            .addResizer(AtMostResizer(maxSide))
            .frameRate(30)
            .keyFrameInterval(2f)
            .bitRate((maxSide * maxSide * 4).toLong())
            .build()

        try {
            job?.cancel(true)
            job = Transcoder.into(out.absolutePath)
                .addDataSource(UriDataSource(ctx, Uri.parse(input.absolutePath)))
                .setVideoTrackStrategy(strategy)
                .setAudioTrackStrategy(
                    DefaultAudioStrategy.builder()
                        .channels(1)
                        .sampleRate(44100)
                        .build(),
                )
                .setListener(object : TranscoderListener {
                    override fun onTranscodeProgress(progress: Double) {}

                    override fun onTranscodeCompleted(successCode: Int) {
                        main.post {
                            if (!out.exists() || out.length() <= 0L) {
                                result.error("empty", "transcode produced empty file", null)
                                return@post
                            }
                            val (ow, oh) = readSize(out.absolutePath)
                            val side = when {
                                ow > 0 && oh > 0 -> minOf(ow, oh).coerceAtMost(maxSide)
                                else -> maxSide
                            }
                            result.success(
                                mapOf(
                                    "path" to out.absolutePath,
                                    "length" to side,
                                    "converted" to true,
                                ),
                            )
                        }
                    }

                    override fun onTranscodeCanceled() {
                        main.post {
                            result.error("canceled", "transcode canceled", null)
                        }
                    }

                    override fun onTranscodeFailed(exception: Throwable) {
                        Log.w(TAG, "transcode failed", exception)
                        main.post {
                            result.error(
                                "transcode",
                                exception.message ?: "transcode failed",
                                null,
                            )
                        }
                    }
                })
                .transcode()
        } catch (e: Exception) {
            Log.w(TAG, "prepareSquare failed", e)
            result.error("transcode", e.message ?: "prepare failed", null)
        }
    }

    private fun readSize(path: String): Pair<Int, Int> {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(path)
            val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 0
            val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 0
            w to h
        } catch (e: Exception) {
            Log.w(TAG, "readSize failed path=$path", e)
            0 to 0
        } finally {
            try {
                r.release()
            } catch (_: Exception) {
            }
        }
    }
}
