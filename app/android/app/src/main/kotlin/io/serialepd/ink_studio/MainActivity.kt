package io.serialepd.ink_studio

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.net.Uri
import android.provider.OpenableColumns
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import io.flutter.embedding.android.FlutterActivity
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class MainActivity : FlutterActivity() {
    private var galleryResult: MethodChannel.Result? = null
    private data class UsbSession(
        val connection: UsbDeviceConnection,
        val controlInterface: UsbInterface?,
        val dataInterface: UsbInterface,
        val input: UsbEndpoint,
        val output: UsbEndpoint,
        val reader: java.util.concurrent.ExecutorService,
        @Volatile var running: Boolean = true,
    )

    private val usbAction = "io.serialepd.ink_studio.USB_PERMISSION"
    private val nextHandle = AtomicInteger(1)
    private val pendingOpen = AtomicReference<io.flutter.plugin.common.MethodChannel.Result?>(null)
    private var permissionReceiver: BroadcastReceiver? = null
    private val sessions = ConcurrentHashMap<Int, UsbSession>()
    private val writes = Executors.newSingleThreadExecutor()
    private var eventSink: EventChannel.EventSink? = null
    private var usbManager: UsbManager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.serialepd/gallery")
            .setMethodCallHandler { call, result ->
                if (call.method != "pickImage") return@setMethodCallHandler result.notImplemented()
                if (galleryResult != null) return@setMethodCallHandler result.error("gallery_busy", "Image selection is already open", null)
                galleryResult = result
                val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                    type = "image/*"
                    addCategory(Intent.CATEGORY_OPENABLE)
                }
                startActivityForResult(Intent.createChooser(intent, "选择图片"), 4102)
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.serialepd/power")
            .setMethodCallHandler { call, result ->
                if (call.method == "keepScreenOn") {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "io.serialepd/usb_cdc").setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val id = call.arguments as? Int
                    val device = usbManager?.deviceList?.values?.firstOrNull { it.deviceId == id }
                    if (device == null) result.error("usb_missing", "USB device is no longer connected", null)
                    else openUsb(device, result)
                }
                "write" -> {
                    val args = call.arguments as? Map<*, *>
                    val session = (args?.get("handle") as? Int)?.let(sessions::get)
                    val bytes = args?.get("data") as? ByteArray
                    if (session == null || bytes == null) result.error("usb_closed", "USB connection is closed", null)
                    else {
                        writes.execute {
                          try {
                            var offset = 0
                            while (offset < bytes.size) {
                                val count = session.connection.bulkTransfer(
                                    session.output, bytes, offset, bytes.size - offset, 3000,
                                )
                                if (count <= 0) error("USB CDC bulk write failed")
                                offset += count
                            }
                            runOnUiThread { result.success(null) }
                          } catch (error: Exception) {
                            runOnUiThread { result.error("usb_write", error.message ?: "USB write failed", null) }
                          }
                        }
                    }
                }
                "close" -> {
                    (call.arguments as? Int)?.let(::closeUsb)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "io.serialepd/usb_cdc_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { eventSink = events }
                override fun onCancel(arguments: Any?) { eventSink = null }
            },
        )
    }

    @Deprecated("Android activity result bridge for the system photo picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4102) return
        val result = galleryResult ?: return
        galleryResult = null
        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        try {
            val uri = data.data!!
            val bytes = readGalleryImage(uri)
            val name = contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (cursor.moveToFirst() && index >= 0) cursor.getString(index) else null
            } ?: "相册图片"
            result.success(mapOf("bytes" to bytes, "name" to name))
        } catch (error: Exception) {
            result.error("gallery_read", error.message ?: "Cannot read selected image", null)
        }
    }

    private fun readGalleryImage(uri: Uri): ByteArray {
        val source = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: error("Cannot read selected image")
        if (source.size <= 25 * 1024 * 1024) return source
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(source, 0, source.size, options)
        var sample = 1
        while ((options.outWidth / sample) * (options.outHeight / sample) > 2_000_000) sample *= 2
        val bitmap = BitmapFactory.decodeByteArray(source, 0, source.size, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: error("Image format is not supported")
        return ByteArrayOutputStream().use { output ->
            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 95, output)
            bitmap.recycle()
            output.toByteArray()
        }
    }

    private fun openUsb(device: UsbDevice, result: MethodChannel.Result) {
        val manager = usbManager ?: return result.error("usb_unavailable", "USB service unavailable", null)
        if (manager.hasPermission(device)) return openPermittedUsb(device, result)
        if (!pendingOpen.compareAndSet(null, result)) {
            return result.error("usb_busy", "Another USB request is pending", null)
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != usbAction) return
                unregisterPermissionReceiver(this)
                val pending = pendingOpen.getAndSet(null) ?: return
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                if (granted) openPermittedUsb(device, pending)
                else pending.error("usb_permission", "USB permission was denied", null)
            }
        }
        val filter = IntentFilter(usbAction)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(receiver, filter)
        }
        permissionReceiver = receiver
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
        try {
            manager.requestPermission(device, PendingIntent.getBroadcast(this, device.deviceId, Intent(usbAction).setPackage(packageName), flags))
        } catch (error: Exception) {
            unregisterPermissionReceiver(receiver)
            pendingOpen.compareAndSet(result, null)
            result.error("usb_permission_request", error.message ?: "Could not request USB permission", null)
        }
    }

    private fun unregisterPermissionReceiver(receiver: BroadcastReceiver) {
        if (permissionReceiver !== receiver) return
        permissionReceiver = null
        try {
            unregisterReceiver(receiver)
        } catch (_: IllegalArgumentException) {
            // The receiver may already have been removed during Activity teardown.
        }
    }

    private fun openPermittedUsb(device: UsbDevice, result: MethodChannel.Result) {
        var connection: UsbDeviceConnection? = null
        var controlClaimed: UsbInterface? = null
        var dataClaimed: UsbInterface? = null
        try {
            val manager = usbManager ?: error("USB service unavailable")
            val control = (0 until device.interfaceCount).map(device::getInterface)
                .firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_COMM }
            val data = (0 until device.interfaceCount).map(device::getInterface)
                .firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_CDC_DATA }
                ?: error("USB CDC data interface was not found")
            val input = (0 until data.endpointCount).map(data::getEndpoint)
                .firstOrNull { it.type == UsbConstants.USB_ENDPOINT_XFER_BULK && it.direction == UsbConstants.USB_DIR_IN }
                ?: error("USB CDC bulk input endpoint was not found")
            val output = (0 until data.endpointCount).map(data::getEndpoint)
                .firstOrNull { it.type == UsbConstants.USB_ENDPOINT_XFER_BULK && it.direction == UsbConstants.USB_DIR_OUT }
                ?: error("USB CDC bulk output endpoint was not found")
            val openedConnection = manager.openDevice(device)
                ?: error("Android could not open the USB device")
            connection = openedConnection
            if (control != null) {
                if (!openedConnection.claimInterface(control, true)) {
                    error("Could not claim USB CDC control interface ${control.id}")
                }
                controlClaimed = control
            }
            if (!openedConnection.claimInterface(data, true)) error("Could not claim USB CDC data interface")
            dataClaimed = data
            if (control != null) {
                val lineCoding = openedConnection.controlTransfer(
                    0x21, 0x20, 0, control.id,
                    byteArrayOf(0, 0xC2.toByte(), 1, 0, 0, 0, 8), 7, 1000,
                )
                if (lineCoding != 7) error("USB CDC rejected 115200 8N1 line coding ($lineCoding)")
                if (openedConnection.controlTransfer(0x21, 0x22, 3, control.id, null, 0, 1000) < 0) {
                    error("USB CDC rejected DTR/RTS control request")
                }
            }
            val handle = nextHandle.getAndIncrement()
            val reader = Executors.newSingleThreadExecutor()
            val session = UsbSession(openedConnection, control, data, input, output, reader)
            sessions[handle] = session
            reader.execute {
                try {
                    val buffer = ByteArray(4096)
                    while (session.running) {
                        val count = openedConnection.bulkTransfer(input, buffer, buffer.size, 200)
                        if (count > 0) {
                            val packet = buffer.copyOf(count)
                            runOnUiThread { if (session.running) eventSink?.success(packet) }
                        } else if (usbManager?.deviceList?.containsKey(device.deviceName) != true) {
                            error("USB device was disconnected")
                        }
                    }
                } catch (error: Exception) {
                    runOnUiThread {
                        if (session.running) {
                            eventSink?.error("usb_read", error.message ?: "USB read failed", null)
                            closeUsb(handle)
                        }
                    }
                }
            }
            result.success(handle)
        } catch (error: Exception) {
            if (connection != null) {
                if (dataClaimed != null) connection.releaseInterface(dataClaimed)
                if (controlClaimed != null) connection.releaseInterface(controlClaimed)
                connection.close()
            }
            result.error("usb_open", error.message ?: error.javaClass.simpleName, null)
        }
    }

    private fun closeUsb(handle: Int) {
        val session = sessions.remove(handle) ?: return
        session.running = false
        session.reader.shutdownNow()
        session.connection.releaseInterface(session.dataInterface)
        session.controlInterface?.let(session.connection::releaseInterface)
        session.connection.close()
    }

    override fun onDestroy() {
        permissionReceiver?.let(::unregisterPermissionReceiver)
        pendingOpen.getAndSet(null)?.error("usb_cancelled", "Activity closed during USB permission request", null)
        sessions.keys.toList().forEach(::closeUsb)
        writes.shutdownNow()
        super.onDestroy()
    }
}
