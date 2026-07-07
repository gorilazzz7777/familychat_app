package com.familychat.familychat_app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private var pendingShareUris: List<Uri> = emptyList()
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        captureShareUris(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureShareUris(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.familychat/share_intent",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "readPendingImageBytes" -> {
                    val index = call.argument<Int>("index") ?: 0
                    val uri = pendingShareUris.getOrNull(index)
                    if (uri == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    try {
                        val bytes = readUriBytesWithOriginal(uri)
                        if (bytes == null || bytes.isEmpty()) {
                            result.success(null)
                        } else {
                            result.success(bytes)
                        }
                    } catch (e: Exception) {
                        result.error("READ_FAILED", e.message, null)
                    }
                }

                "clearPendingShareUris" -> {
                    pendingShareUris = emptyList()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun captureShareUris(intent: Intent?) {
        pendingShareUris = when (intent?.action) {
            Intent.ACTION_SEND -> {
                val uri = readStreamUri(intent)
                if (uri != null) listOf(uri) else emptyList()
            }

            Intent.ACTION_SEND_MULTIPLE -> {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
            }

            else -> emptyList()
        }
    }

    private fun readStreamUri(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
    }

    private fun readUriBytesWithOriginal(uri: Uri): ByteArray? {
        val resolver = applicationContext.contentResolver
        val mediaUri =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    MediaStore.setRequireOriginal(uri)
                } catch (_: Exception) {
                    uri
                }
            } else {
                uri
            }
        return resolver.openInputStream(mediaUri)?.use { input -> input.readBytes() }
    }
}
