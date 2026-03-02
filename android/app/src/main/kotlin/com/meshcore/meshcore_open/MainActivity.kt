package com.meshcore.meshcore_open

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.hoho.android.usbserial.driver.UsbSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val usbMethodChannelName = "meshcore_open/android_usb_serial"
    private val usbEventChannelName = "meshcore_open/android_usb_serial_events"
    private val usbPermissionAction = "com.meshcore.meshcore_open.USB_PERMISSION"

    private lateinit var usbManager: UsbManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val usbIoExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private var eventSink: EventChannel.EventSink? = null
    private var usbConnection: UsbDeviceConnection? = null
    private var usbPort: UsbSerialPort? = null
    private var ioManager: SerialInputOutputManager? = null
    private var connectedDeviceName: String? = null

    private var pendingConnectResult: MethodChannel.Result? = null
    private var pendingConnectPortName: String? = null
    private var pendingConnectBaudRate: Int = 115200

    private val permissionReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                        handleUsbDetached(intent)
                        return
                    }
                    usbPermissionAction -> {
                    }
                    else -> {
                        return
                    }
                }

                if (intent.action != usbPermissionAction) {
                    return
                }

                val result = pendingConnectResult
                val portName = pendingConnectPortName
                pendingConnectResult = null
                pendingConnectPortName = null

                if (result == null || portName == null) {
                    return
                }

                val granted =
                    intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                if (!granted) {
                    result.error("usb_permission_denied", "USB permission denied", null)
                    return
                }

                val device = findUsbDevice(portName)
                if (device == null) {
                    result.error(
                        "usb_device_missing",
                        "USB device no longer available for $portName",
                        null,
                    )
                    return
                }

                openUsbDevice(device, pendingConnectBaudRate, result)
            }
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        registerUsbPermissionReceiver()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, usbMethodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listPorts" -> result.success(listUsbPorts())
                    "connect" -> handleUsbConnect(call, result)
                    "write" -> handleUsbWrite(call, result)
                    "disconnect" -> {
                        usbIoExecutor.execute {
                            closeUsbConnection()
                            mainHandler.post {
                                result.success(null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, usbEventChannelName)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                        eventSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        eventSink = null
                    }
                },
            )
    }

    override fun onDestroy() {
        closeUsbConnection()
        usbIoExecutor.shutdownNow()
        try {
            unregisterReceiver(permissionReceiver)
        } catch (_: IllegalArgumentException) {
        }
        super.onDestroy()
    }

    private fun registerUsbPermissionReceiver() {
        val filter =
            IntentFilter().apply {
                addAction(usbPermissionAction)
                addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(permissionReceiver, filter)
        }
    }

    private fun listUsbPorts(): List<String> {
        val drivers = UsbSerialProber.getDefaultProber().findAllDrivers(usbManager)
        return drivers.map { driver ->
            val device = driver.device
            val productName = device.productName ?: "USB Serial Device"
            val vendorProduct =
                String.format(
                    Locale.US,
                    "VID:%04X PID:%04X",
                    device.vendorId,
                    device.productId,
                )
            "${device.deviceName} - $productName - $vendorProduct"
        }
    }

    private fun handleUsbConnect(call: MethodCall, result: MethodChannel.Result) {
        val portName = call.argument<String>("portName")
        val baudRate = call.argument<Int>("baudRate") ?: 115200
        if (portName.isNullOrBlank()) {
            result.error("usb_invalid_port", "Port name is required", null)
            return
        }

        val device = findUsbDevice(portName)
        if (device == null) {
            result.error("usb_device_missing", "USB device not found for $portName", null)
            return
        }

        if (usbManager.hasPermission(device)) {
            openUsbDevice(device, baudRate, result)
            return
        }

        if (pendingConnectResult != null) {
            result.error("usb_busy", "Another USB permission request is already pending", null)
            return
        }

        pendingConnectResult = result
        pendingConnectPortName = portName
        pendingConnectBaudRate = baudRate

        val permissionIntent = PendingIntent.getBroadcast(
            this,
            0,
            Intent(usbPermissionAction).setPackage(packageName),
            pendingIntentFlags(),
        )
        usbManager.requestPermission(device, permissionIntent)
    }

    private fun handleUsbWrite(call: MethodCall, result: MethodChannel.Result) {
        val data = call.argument<ByteArray>("data")
        val port = usbPort
        if (data == null) {
            result.error("usb_invalid_data", "Data is required", null)
            return
        }
        if (port == null) {
            result.error("usb_not_connected", "USB serial port is not connected", null)
            return
        }

        usbIoExecutor.execute {
            try {
                port.write(data, 1000)
                mainHandler.post {
                    result.success(null)
                }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error("usb_write_failed", error.message, null)
                }
            }
        }
    }

    private fun findUsbDevice(portName: String): UsbDevice? {
        return usbManager.deviceList.values.firstOrNull { it.deviceName == portName }
    }

    private fun openUsbDevice(
        device: UsbDevice,
        baudRate: Int,
        result: MethodChannel.Result,
    ) {
        usbIoExecutor.execute {
            try {
                closeUsbConnection()

                val driver = UsbSerialProber.getDefaultProber().probeDevice(device)
                if (driver == null) {
                    mainHandler.post {
                        result.error(
                            "usb_driver_missing",
                            "No USB serial driver for ${device.deviceName}",
                            null,
                        )
                    }
                    return@execute
                }

                val connection = usbManager.openDevice(device)
                if (connection == null) {
                    mainHandler.post {
                        result.error(
                            "usb_open_failed",
                            "UsbManager could not open ${device.deviceName}",
                            null,
                        )
                    }
                    return@execute
                }

                val port = firstPort(driver)
                if (port == null) {
                    connection.close()
                    mainHandler.post {
                        result.error(
                            "usb_port_missing",
                            "No USB serial port exposed by ${device.deviceName}",
                            null,
                        )
                    }
                    return@execute
                }

                port.open(connection)
                port.setParameters(
                    baudRate,
                    8,
                    UsbSerialPort.STOPBITS_1,
                    UsbSerialPort.PARITY_NONE,
                )
                port.rts = false
                port.dtr = true

                usbConnection = connection
                usbPort = port
                connectedDeviceName = device.deviceName

                ioManager =
                    SerialInputOutputManager(
                        port,
                        object : SerialInputOutputManager.Listener {
                            override fun onNewData(data: ByteArray) {
                                mainHandler.post {
                                    eventSink?.success(data)
                                }
                            }

                            override fun onRunError(e: Exception) {
                                mainHandler.post {
                                    eventSink?.error(
                                        "usb_io_error",
                                        e.message ?: "USB serial I/O error",
                                        null,
                                    )
                                }
                                closeUsbConnection()
                            }
                        },
                    ).also { manager ->
                        manager.start()
                    }

                mainHandler.post {
                    result.success(null)
                }
            } catch (error: Exception) {
                closeUsbConnection()
                mainHandler.post {
                    result.error("usb_connect_failed", error.message, null)
                }
            }
        }
    }

    private fun firstPort(driver: UsbSerialDriver): UsbSerialPort? {
        return driver.ports.firstOrNull()
    }

    private fun closeUsbConnection() {
        try {
            ioManager?.stop()
        } catch (_: Exception) {
        }
        ioManager = null

        try {
            usbPort?.close()
        } catch (_: Exception) {
        }
        usbPort = null

        try {
            usbConnection?.close()
        } catch (_: Exception) {
        }
        usbConnection = null
        connectedDeviceName = null
    }

    private fun handleUsbDetached(intent: Intent) {
        val detachedDevice =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }

        val detachedName = detachedDevice?.deviceName ?: return

        if (pendingConnectPortName == detachedName) {
            pendingConnectResult?.error(
                "usb_device_detached",
                "USB device was removed before the connection completed",
                null,
            )
            pendingConnectResult = null
            pendingConnectPortName = null
        }

        if (connectedDeviceName == detachedName) {
            closeUsbConnection()
            eventSink?.error(
                "usb_device_detached",
                "USB device was disconnected",
                null,
            )
        }
    }

    private fun pendingIntentFlags(): Int {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flags = flags or PendingIntent.FLAG_MUTABLE
        }
        return flags
    }
}
