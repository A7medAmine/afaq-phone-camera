package com.afaq.afaq_phone_camera

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "afaq/jpeg")
            .setMethodCallHandler { call, result ->
                if (call.method != "encode") return@setMethodCallHandler result.notImplemented()
                worker.execute {
                    try {
                        val jpeg = encode(
                            call.argument<ByteArray>("y")!!,
                            call.argument<ByteArray>("u")!!,
                            call.argument<ByteArray>("v")!!,
                            call.argument<Int>("w")!!,
                            call.argument<Int>("h")!!,
                            call.argument<Int>("yStride")!!,
                            call.argument<Int>("uvStride")!!,
                            call.argument<Int>("uvPixel")!!,
                            call.argument<Int>("rotation")!!,
                            call.argument<Int>("quality")!!,
                        )
                        main.post { result.success(jpeg) }
                    } catch (e: Exception) {
                        main.post { result.error("encode", e.toString(), null) }
                    }
                }
            }
    }

    // Builds a rotated NV21 buffer straight from the camera planes, then lets Android compress it.
    private fun encode(
        y: ByteArray, u: ByteArray, v: ByteArray, w: Int, h: Int,
        yStride: Int, uvStride: Int, uvPixel: Int, rotation: Int, quality: Int,
    ): ByteArray {
        val swap = rotation == 90 || rotation == 270
        val rw = if (swap) h else w
        val rh = if (swap) w else h
        val out = ByteArray(rw * rh * 3 / 2)
        for (row in 0 until h) {
            val base = row * yStride
            for (col in 0 until w) {
                val d = when (rotation) {
                    90 -> col * rw + (h - 1 - row)
                    180 -> (h - 1 - row) * rw + (w - 1 - col)
                    270 -> (w - 1 - col) * rw + row
                    else -> row * rw + col
                }
                out[d] = y[base + col]
            }
        }
        val cw = w / 2
        val ch = h / 2
        val off = rw * rh
        for (row in 0 until ch) {
            val base = row * uvStride
            for (col in 0 until cw) {
                val i = base + col * uvPixel
                val nx: Int
                val ny: Int
                when (rotation) {
                    90 -> { nx = ch - 1 - row; ny = col }
                    180 -> { nx = cw - 1 - col; ny = ch - 1 - row }
                    270 -> { nx = row; ny = cw - 1 - col }
                    else -> { nx = col; ny = row }
                }
                val d = off + ny * rw + nx * 2
                out[d] = v[i]
                out[d + 1] = u[i]
            }
        }
        val bos = ByteArrayOutputStream(rw * rh / 6)
        YuvImage(out, ImageFormat.NV21, rw, rh, null).compressToJpeg(Rect(0, 0, rw, rh), quality, bos)
        return bos.toByteArray()
    }
}
