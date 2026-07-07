package com.familychat.familychat_app

import android.Manifest
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "FamilyChatShare"
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
                        Log.w(TAG, "readPendingImageBytes: no uri for index=$index count=${pendingShareUris.size}")
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    try {
                        val bytes = readUriBytesWithOriginal(uri)
                        Log.i(
                            TAG,
                            "readPendingImageBytes: uri=$uri bytes=${bytes?.size ?: 0}",
                        )
                        if (bytes == null || bytes.isEmpty()) {
                            result.success(null)
                        } else {
                            result.success(bytes)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "readPendingImageBytes failed", e)
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
                val fromExtra = readStreamUri(intent)
                if (fromExtra != null) {
                    listOf(fromExtra)
                } else {
                    readClipUris(intent)
                }
            }

            Intent.ACTION_SEND_MULTIPLE -> {
                val fromExtra =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                    }
                if (!fromExtra.isNullOrEmpty()) fromExtra else readClipUris(intent)
            }

            else -> emptyList()
        }
        Log.i(TAG, "captureShareUris action=${intent?.action} count=${pendingShareUris.size} uris=$pendingShareUris")
    }

    private fun readStreamUri(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
    }

    private fun readClipUris(intent: Intent): List<Uri> {
        val clip: ClipData = intent.clipData ?: return emptyList()
        val uris = ArrayList<Uri>(clip.itemCount)
        for (i in 0 until clip.itemCount) {
            clip.getItemAt(i).uri?.let { uris.add(it) }
        }
        return uris
    }

    private fun readUriBytesWithOriginal(uri: Uri): ByteArray? {
        val resolver = applicationContext.contentResolver
        val canRequireOriginal =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                hasMediaLocationAccess()
        val mediaUri =
            if (canRequireOriginal) {
                try {
                    MediaStore.setRequireOriginal(uri)
                } catch (e: Exception) {
                    Log.w(TAG, "setRequireOriginal failed for $uri", e)
                    uri
                }
            } else {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    Log.i(TAG, "readUriBytes: ACCESS_MEDIA_LOCATION not granted, reading without requireOriginal")
                }
                uri
            }
        return resolver.openInputStream(mediaUri)?.use { input -> input.readBytes() }
    }

    private fun hasMediaLocationAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_MEDIA_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
    }
}
