package com.familychat.familychat_app

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import kotlin.math.abs

/**
 * Raise-to-listen for voice messages — port of Telegram
 * `MediaController.onSensorChanged` listen path + `setUseFrontSpeaker`.
 *
 * Audio routing is **speakerphone only** (no MODE_IN_COMMUNICATION). Dart
 * recreates the player with MUSIC vs VOICE_CALL usage (`startAudioAgain`).
 */
class VoiceRaiseToListenController(
    private val context: Context,
    private val onEvent: (Map<String, Any?>) -> Unit,
) : SensorEventListener {
    companion object {
        private const val TAG = "FamilyChatVoice"
    }

    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val powerManager =
        context.getSystemService(Context.POWER_SERVICE) as PowerManager

    private var proximitySensor: Sensor? = null
    private var accelerometerSensor: Sensor? = null
    private var gravitySensor: Sensor? = null
    private var linearSensor: Sensor? = null

    private var sensorsStarted = false
    private var voicePlaying = false
    private var useFrontSpeaker = false

    private var proximityTouched = false
    private var proximityHasDifferentValues = false
    private var lastProximityValue = -100f
    private var proximityDist: Float? = null
    private var proximityMaxRange = 5f

    private var raisedToTop = 0
    private var raisedToTopSign = 0
    private var raisedToBack = 0
    private var countLess = 0
    private var previousAccValue = 0f
    private var lastTimestamp = 0L
    private var lastAccelerometerDetected = 0L
    private var timeSinceRaise = 0L
    private var accelerometerVertical = false

    private val gravity = FloatArray(3)
    private val gravityFast = FloatArray(3)
    private val linearAcceleration = FloatArray(3)

    private var proximityWakeLock: PowerManager.WakeLock? = null

    /** @return true if a proximity sensor exists. */
    fun start(): Boolean {
        stopSensorsOnly()
        val prox = sensorManager.getDefaultSensor(Sensor.TYPE_PROXIMITY) ?: return false
        proximitySensor = prox
        proximityMaxRange = prox.maximumRange
        proximityHasDifferentValues = false
        lastProximityValue = -100f
        proximityTouched = false
        proximityDist = null
        resetMotion()

        val gravity = sensorManager.getDefaultSensor(Sensor.TYPE_GRAVITY)
        val linear = sensorManager.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
        if (gravity != null && linear != null) {
            gravitySensor = gravity
            linearSensor = linear
            accelerometerSensor = null
        } else {
            gravitySensor = null
            linearSensor = null
            accelerometerSensor = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        }

        @Suppress("DEPRECATION")
        proximityWakeLock = powerManager.newWakeLock(
            PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
            "familychat:voice_proximity",
        )

        sensorManager.registerListener(this, prox, SensorManager.SENSOR_DELAY_NORMAL)
        gravitySensor?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        linearSensor?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        accelerometerSensor?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        sensorsStarted = true
        Log.i(
            TAG,
            "VoiceRaiseToListen start prox=${prox.name} max=$proximityMaxRange " +
                "accel=${accelerometerSensor != null} gravity=${gravitySensor != null} " +
                "linear=${linearSensor != null}",
        )
        emit("sensor_start")
        return true
    }

    fun stop() {
        voicePlaying = false
        if (useFrontSpeaker) {
            setUseFrontSpeaker(false, notify = false)
        }
        releaseWakeLock()
        stopSensorsOnly()
        proximityWakeLock = null
        proximityTouched = false
        proximityDist = null
        proximityHasDifferentValues = false
        resetMotion()
        Log.i(TAG, "VoiceRaiseToListen stop")
        emit("stop")
    }

    fun setPlaying(playing: Boolean) {
        voicePlaying = playing
        Log.i(TAG, "VoiceRaiseToListen setPlaying=$playing")
        if (!playing) {
            if (useFrontSpeaker) {
                setUseFrontSpeaker(false, notify = false)
            }
            releaseWakeLock()
            emit("playing_false")
            return
        }
        // Default loudspeaker (TG: STREAM_MUSIC / speaker on).
        if (useFrontSpeaker) {
            setUseFrontSpeaker(false, notify = false)
        } else {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = true
        }
        evaluateSensors(reason = "playing_true")
    }

    /** Explicit Dart/native toggle (prepare / reassert). Speakerphone only. */
    fun setEarpiece(earpiece: Boolean) {
        setUseFrontSpeaker(earpiece, notify = true)
    }

    fun snapshot(reason: String): Map<String, Any?> = buildSnapshot(reason)

    private fun stopSensorsOnly() {
        if (!sensorsStarted) return
        sensorManager.unregisterListener(this)
        sensorsStarted = false
        proximitySensor = null
        accelerometerSensor = null
        gravitySensor = null
        linearSensor = null
    }

    private fun resetMotion() {
        raisedToTop = 0
        raisedToTopSign = 0
        raisedToBack = 0
        countLess = 0
        previousAccValue = 0f
        lastTimestamp = 0L
        lastAccelerometerDetected = 0L
        timeSinceRaise = 0L
        accelerometerVertical = false
        gravity.fill(0f)
        gravityFast.fill(0f)
        linearAcceleration.fill(0f)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    override fun onSensorChanged(event: SensorEvent?) {
        if (!sensorsStarted || event == null || event.values.isEmpty()) return

        val prox = proximitySensor
        when {
            event.sensor.type == Sensor.TYPE_PROXIMITY && prox != null -> {
                val dist = event.values[0]
                proximityDist = dist
                if (lastProximityValue != dist) {
                    proximityHasDifferentValues = true
                }
                lastProximityValue = dist
                if (proximityHasDifferentValues) {
                    proximityTouched = isNearToSensor(dist, prox)
                }
            }
            event.sensor == accelerometerSensor -> {
                val alpha =
                    if (lastTimestamp == 0L) {
                        0.98
                    } else {
                        1.0 / (1.0 + (event.timestamp - lastTimestamp) / 1_000_000_000.0)
                    }
                lastTimestamp = event.timestamp
                val alphaFast = 0.8f
                for (i in 0..2) {
                    gravity[i] =
                        (alpha * gravity[i] + (1.0 - alpha) * event.values[i]).toFloat()
                    gravityFast[i] =
                        alphaFast * gravity[i] + (1.0f - alphaFast) * event.values[i]
                    linearAcceleration[i] = event.values[i] - gravity[i]
                }
            }
            event.sensor == linearSensor -> {
                linearAcceleration[0] = event.values[0]
                linearAcceleration[1] = event.values[1]
                linearAcceleration[2] = event.values[2]
            }
            event.sensor == gravitySensor -> {
                gravity[0] = event.values[0]
                gravity[1] = event.values[1]
                gravity[2] = event.values[2]
                gravityFast[0] = event.values[0]
                gravityFast[1] = event.values[1]
                gravityFast[2] = event.values[2]
            }
        }

        // TG raise-to-back gesture (listen path uses accelerometerVertical /
        // raisedToBack for wakelockAllowed).
        val minDist = 15.0f
        val minCount = 6
        val countLessMax = 10
        if (event.sensor == linearSensor ||
            event.sensor == gravitySensor ||
            event.sensor == accelerometerSensor
        ) {
            val value =
                gravity[0] * linearAcceleration[0] +
                    gravity[1] * linearAcceleration[1] +
                    gravity[2] * linearAcceleration[2]
            if (raisedToBack != minCount) {
                if ((value > 0 && previousAccValue > 0) ||
                    (value < 0 && previousAccValue < 0)
                ) {
                    val goodValue: Boolean
                    val sign: Int
                    if (value > 0) {
                        goodValue = value > minDist
                        sign = 1
                    } else {
                        goodValue = value < -minDist
                        sign = 2
                    }
                    if (raisedToTopSign != 0 && raisedToTopSign != sign) {
                        if (raisedToTop == minCount && goodValue) {
                            if (raisedToBack < minCount) {
                                raisedToBack++
                                if (raisedToBack == minCount) {
                                    raisedToTop = 0
                                    raisedToTopSign = 0
                                    countLess = 0
                                    timeSinceRaise = System.currentTimeMillis()
                                    Log.i(TAG, "motion detected")
                                }
                            }
                        } else {
                            if (!goodValue) countLess++
                            if (countLess == countLessMax ||
                                raisedToTop != minCount ||
                                raisedToBack != 0
                            ) {
                                raisedToTop = 0
                                raisedToTopSign = 0
                                raisedToBack = 0
                                countLess = 0
                            }
                        }
                    } else {
                        if (goodValue && raisedToBack == 0 &&
                            (raisedToTopSign == 0 || raisedToTopSign == sign)
                        ) {
                            if (raisedToTop < minCount && !proximityTouched) {
                                raisedToTopSign = sign
                                raisedToTop++
                                if (raisedToTop == minCount) {
                                    countLess = 0
                                }
                            }
                        } else {
                            if (!goodValue) countLess++
                            if (raisedToTopSign != sign ||
                                countLess == countLessMax ||
                                raisedToTop != minCount ||
                                raisedToBack != 0
                            ) {
                                raisedToBack = 0
                                raisedToTop = 0
                                raisedToTopSign = 0
                                countLess = 0
                            }
                        }
                    }
                }
            }
            previousAccValue = value
            accelerometerVertical =
                gravityFast[1] > 2.5f &&
                    abs(gravityFast[2]) < 4.0f &&
                    abs(gravityFast[0]) > 1.5f
        }

        if (raisedToBack == minCount || accelerometerVertical) {
            lastAccelerometerDetected = System.currentTimeMillis()
        }

        evaluateSensors(reason = "sensor")

        if (timeSinceRaise != 0L &&
            raisedToBack == minCount &&
            abs(System.currentTimeMillis() - timeSinceRaise) > 1000
        ) {
            raisedToBack = 0
            raisedToTop = 0
            raisedToTopSign = 0
            countLess = 0
            timeSinceRaise = 0L
        }
    }

    /**
     * TG listen branch (allowListening=true while [voicePlaying]).
     * No recording / VoIP / PhotoViewer gates — those are N/A here.
     */
    private fun evaluateSensors(reason: String) {
        if (!sensorsStarted) return
        val allowListening = voicePlaying
        val minCount = 6
        val accelerometerDetected =
            raisedToBack == minCount ||
                accelerometerVertical ||
                System.currentTimeMillis() - lastAccelerometerDetected < 60
        val alreadyPlaying = useFrontSpeaker
        val headsetForbidden = forbidRaiseToListen()
        // TG: ((accel == null || linear == null) && gravity == null)
        val noMotionSensors =
            (accelerometerSensor == null || linearSensor == null) &&
                gravitySensor == null
        val wakelockAllowed =
            (accelerometerDetected || alreadyPlaying) &&
                !headsetForbidden &&
                allowListening

        updateWakeLock(wakelockAllowed)

        if (proximityTouched && wakelockAllowed) {
            if (allowListening && !useFrontSpeaker) {
                Log.i(TAG, "start listen why=$reason")
                setUseFrontSpeaker(true, notify = true)
            }
            raisedToBack = 0
            raisedToTop = 0
            raisedToTopSign = 0
            countLess = 0
        } else if (proximityTouched && noMotionSensors && allowListening) {
            // TG: start listen by proximity only (no accel sensors).
            if (!useFrontSpeaker && !headsetForbidden) {
                Log.i(TAG, "start listen by proximity only why=$reason")
                setUseFrontSpeaker(true, notify = true)
            }
        } else if (!proximityTouched) {
            if (useFrontSpeaker) {
                Log.i(TAG, "stop listen why=$reason")
                setUseFrontSpeaker(false, notify = true)
            } else if (reason != "sensor") {
                emit(reason)
            }
        } else if (reason != "sensor") {
            emit(reason)
        }
    }

    private fun isNearToSensor(value: Float, prox: Sensor): Boolean {
        return value < 5.0f && value != prox.maximumRange
    }

    private fun forbidRaiseToListen(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                devices.any { device ->
                    val type = device.type
                    val ble = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && (
                        type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                            type == AudioDeviceInfo.TYPE_BLE_SPEAKER
                        )
                    device.isSink && (
                        type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                            type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                            ble ||
                            type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                            type == AudioDeviceInfo.TYPE_WIRED_HEADSET
                        )
                }
            } else {
                @Suppress("DEPRECATION")
                audioManager.isWiredHeadsetOn ||
                    audioManager.isBluetoothA2dpOn ||
                    audioManager.isBluetoothScoOn
            }
        } catch (e: Exception) {
            Log.w(TAG, "forbidRaiseToListen: $e")
            false
        }
    }

    /** TG setUseFrontSpeaker — speakerphone only, no AudioManager.mode. */
    private fun setUseFrontSpeaker(value: Boolean, notify: Boolean) {
        val changed = useFrontSpeaker != value
        useFrontSpeaker = value
        @Suppress("DEPRECATION")
        if (useFrontSpeaker) {
            audioManager.isBluetoothScoOn = false
            audioManager.isSpeakerphoneOn = false
        } else {
            audioManager.isSpeakerphoneOn = true
        }
        Log.i(TAG, "setUseFrontSpeaker front=$value changed=$changed")
        if (notify) {
            emit(if (changed) "route_change" else "route_same")
        }
    }

    private fun updateWakeLock(allowed: Boolean) {
        val lock = proximityWakeLock ?: return
        val held = lock.isHeld
        if (held && !allowed) {
            Log.i(TAG, "wake lock releasing")
            lock.release()
        } else if (!held && allowed) {
            Log.i(TAG, "wake lock acquiring")
            lock.acquire()
        }
    }

    private fun releaseWakeLock() {
        val lock = proximityWakeLock ?: return
        if (lock.isHeld) {
            Log.i(TAG, "wake lock release (stop)")
            lock.release()
        }
    }

    private fun emit(reason: String) {
        onEvent(buildSnapshot(reason))
    }

    @Suppress("DEPRECATION")
    private fun buildSnapshot(reason: String): Map<String, Any?> {
        val mode = audioManager.mode
        val speakerOn = audioManager.isSpeakerphoneOn
        val modeName = when (mode) {
            AudioManager.MODE_NORMAL -> "NORMAL"
            AudioManager.MODE_RINGTONE -> "RINGTONE"
            AudioManager.MODE_IN_CALL -> "IN_CALL"
            AudioManager.MODE_IN_COMMUNICATION -> "IN_COMMUNICATION"
            else -> "mode_$mode"
        }
        val minCount = 6
        val raised =
            raisedToBack == minCount ||
                accelerometerVertical ||
                System.currentTimeMillis() - lastAccelerometerDetected < 60
        return hashMapOf(
            "reason" to reason,
            "mode" to modeName,
            "modeInt" to mode,
            "speakerOn" to speakerOn,
            "musicVol" to audioManager.getStreamVolume(AudioManager.STREAM_MUSIC),
            "musicMax" to audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
            "voiceVol" to audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL),
            "voiceMax" to audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL),
            "wiredHeadset" to audioManager.isWiredHeadsetOn,
            "btA2dp" to audioManager.isBluetoothA2dpOn,
            "btSco" to audioManager.isBluetoothScoOn,
            "headsetForbidden" to forbidRaiseToListen(),
            "voiceProxHeld" to (proximityWakeLock?.isHeld == true),
            "near" to proximityTouched,
            "wantFrontSpeaker" to useFrontSpeaker,
            "playing" to voicePlaying,
            "raised" to raised,
            "hasAccel" to (accelerometerSensor != null || gravitySensor != null),
            "dist" to proximityDist?.toDouble(),
            "maxRange" to proximityMaxRange.toDouble(),
            "uptimeMs" to SystemClock.uptimeMillis(),
        )
    }
}
