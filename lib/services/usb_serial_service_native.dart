import 'dart:async';

import 'package:flserial/flserial.dart';
import 'package:flserial/flserial_exception.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_debug_log_service.dart';
import '../utils/platform_info.dart';
import '../utils/usb_port_labels.dart';
import 'usb_serial_frame_codec.dart';

/// Wraps the native flserial plugin to expose a stream of raw bytes for the
/// MeshCore connector to consume.
class UsbSerialService {
  UsbSerialService();

  static const MethodChannel _androidMethodChannel = MethodChannel(
    'meshcore_open/android_usb_serial',
  );
  static const EventChannel _androidEventChannel = EventChannel(
    'meshcore_open/android_usb_serial_events',
  );
  final StreamController<Uint8List> _frameController =
      StreamController<Uint8List>.broadcast();
  final UsbSerialFrameDecoder _frameDecoder = UsbSerialFrameDecoder();
  StreamSubscription<dynamic>? _androidDataSubscription;
  StreamSubscription<FlSerialEventArgs>? _dataSubscription;
  UsbSerialStatus _status = UsbSerialStatus.disconnected;
  String? _connectedPortKey;
  String? _connectedPortLabel;
  FlSerial? _serial;
  AppDebugLogService? _debugLogService;

  UsbSerialStatus get status => _status;
  String? get activePortKey => _connectedPortKey;
  String? get activePortDisplayLabel =>
      _connectedPortLabel ?? _connectedPortKey;
  Stream<Uint8List> get frameStream => _frameController.stream;
  bool get _useAndroidUsbHost =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _useDesktopFlSerial =>
      PlatformInfo.isWindows || PlatformInfo.isLinux;
  bool get _isSupportedPlatform => _useAndroidUsbHost || _useDesktopFlSerial;
  FlSerial get _nativeSerial => _serial ??= FlSerial();

  bool get isConnected {
    if (!_isSupportedPlatform) {
      return false;
    }
    if (_useAndroidUsbHost) {
      return _status == UsbSerialStatus.connected;
    }
    return _status == UsbSerialStatus.connected &&
        _serial?.isOpen() == FlOpenStatus.open;
  }

  Future<List<String>> listPorts() async {
    if (!_isSupportedPlatform) {
      return const <String>[];
    }
    if (_useAndroidUsbHost) {
      final ports = await _androidMethodChannel.invokeListMethod<String>(
        'listPorts',
      );
      return ports ?? <String>[];
    }
    return Future.value(FlSerial.listPorts());
  }

  void setDebugLogService(AppDebugLogService? service) {
    _debugLogService = service;
  }

  Future<void> connect({
    required String portName,
    int baudRate = 115200,
  }) async {
    if (_status == UsbSerialStatus.connected ||
        _status == UsbSerialStatus.connecting) {
      throw StateError('USB serial transport is already active');
    }
    if (!_isSupportedPlatform) {
      throw UnsupportedError('USB serial is not supported on this platform.');
    }

    _status = UsbSerialStatus.connecting;
    final normalizedPortName = normalizeUsbPortName(portName);
    _frameDecoder.reset();

    if (_useAndroidUsbHost) {
      try {
        await _androidMethodChannel.invokeMethod<void>('connect', {
          'portName': normalizedPortName,
          'baudRate': baudRate,
        });
        _debugLogService?.info(
          'USB serial opened port=$normalizedPortName on Android via USB host bridge',
          tag: 'USB Serial',
        );
      } on PlatformException catch (error) {
        _status = UsbSerialStatus.disconnected;
        throw StateError(error.message ?? error.code);
      }
    } else {
      final serial = _nativeSerial;
      serial.init();

      try {
        final status = serial.openPort(normalizedPortName, baudRate);
        if (status != FlOpenStatus.open) {
          throw StateError(
            'Failed to open USB port $normalizedPortName ($status)',
          );
        }
        serial.setByteSize8();
        serial.setBitParityNone();
        serial.setStopBits1();
        serial.setFlowControlNone();
        serial.setRTS(false);
        serial.setDTR(true);
        _debugLogService?.info(
          'USB serial opened port=$normalizedPortName cts=${serial.getCTS()} dsr=${serial.getDSR()} dtr=true rts=false',
          tag: 'USB Serial',
        );
      } on FlSerialException catch (error) {
        _serial?.free();
        _serial = null;
        _status = UsbSerialStatus.disconnected;
        throw StateError(
          'Failed to open USB port $normalizedPortName: ${error.msg} (${error.error})',
        );
      } catch (error) {
        _serial?.free();
        _serial = null;
        _status = UsbSerialStatus.disconnected;
        rethrow;
      }
    }

    _connectedPortKey = normalizedPortName;
    _connectedPortLabel = normalizedPortName;
    if (_useAndroidUsbHost) {
      _androidDataSubscription = _androidEventChannel
          .receiveBroadcastStream()
          .listen(
            _handleAndroidData,
            onError: _handleSerialError,
            onDone: _handleSerialDone,
          );
    } else {
      _dataSubscription = _nativeSerial.onSerialData.stream.listen(
        _handleSerialData,
        onError: _handleSerialError,
        onDone: _handleSerialDone,
      );
    }
    _status = UsbSerialStatus.connected;
  }

  Future<void> write(Uint8List data) async {
    if (!isConnected) {
      throw StateError('USB serial port is not open');
    }
    final packet = wrapUsbSerialTxFrame(data);
    _logFrameSummary('USB TX frame', data);
    if (_useAndroidUsbHost) {
      try {
        await _androidMethodChannel.invokeMethod<void>('write', {
          'data': packet,
        });
      } on PlatformException catch (error) {
        throw StateError(error.message ?? error.code);
      }
    } else {
      _nativeSerial.write(packet);
    }
  }

  Future<void> disconnect() async {
    if (_status == UsbSerialStatus.disconnected) return;

    _status = UsbSerialStatus.disconnecting;
    _connectedPortKey = null;
    _connectedPortLabel = null;
    _frameDecoder.reset();
    await _androidDataSubscription?.cancel();
    _androidDataSubscription = null;
    await _dataSubscription?.cancel();
    _dataSubscription = null;

    if (_useAndroidUsbHost) {
      try {
        await _androidMethodChannel.invokeMethod<void>('disconnect');
      } catch (_) {
        // Ignore errors while closing.
      }
    } else {
      try {
        if (_serial?.isOpen() == FlOpenStatus.open) {
          _serial?.closePort();
        }
      } catch (_) {
        // Ignore errors while closing.
      }

      _serial?.free();
      _serial = null;
    }
    _status = UsbSerialStatus.disconnected;
  }

  void setRequestPortLabel(String label) {
    // Native implementations do not use a synthetic chooser row.
  }

  void updateConnectedLabel(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      return;
    }
    _connectedPortLabel = buildUsbDisplayLabel(
      basePortLabel: _connectedPortKey ?? trimmed,
      deviceName: trimmed,
    );
  }

  void dispose() {
    unawaited(disconnect().whenComplete(_closeFrameController));
  }

  void _handleSerialData(FlSerialEventArgs event) {
    try {
      final bytes = event.serial.readList();
      if (bytes.isNotEmpty) {
        _ingestRawBytes(Uint8List.fromList(bytes));
      }
    } catch (error, stack) {
      _addFrameError(error, stack);
    }
  }

  void _handleAndroidData(dynamic data) {
    if (data is Uint8List) {
      _ingestRawBytes(data);
      return;
    }
    if (data is ByteData) {
      _ingestRawBytes(data.buffer.asUint8List());
      return;
    }
    _addFrameError(
      StateError('Unexpected Android USB event payload: ${data.runtimeType}'),
    );
  }

  void _handleSerialError(Object error, [StackTrace? stackTrace]) {
    _addFrameError(error, stackTrace);
  }

  void _handleSerialDone() {
    unawaited(disconnect());
  }

  void _ingestRawBytes(Uint8List bytes) {
    for (final packet in _frameDecoder.ingest(bytes)) {
      if (!packet.isRxFrame) {
        _debugLogService?.info(
          'USB ignored packet start=0x${packet.frameStart.toRadixString(16).padLeft(2, '0')} len=${packet.payload.length}',
          tag: 'USB Serial',
        );
        continue;
      }
      _addFrame(packet.payload);
    }
  }

  void _addFrame(Uint8List payload) {
    if (_frameController.isClosed) {
      return;
    }
    _frameController.add(payload);
  }

  void _addFrameError(Object error, [StackTrace? stackTrace]) {
    if (_frameController.isClosed) {
      return;
    }
    _frameController.addError(error, stackTrace);
  }

  Future<void> _closeFrameController() async {
    if (_frameController.isClosed) {
      return;
    }
    await _frameController.close();
  }

  void _logFrameSummary(String prefix, Uint8List bytes) {
    if (bytes.isEmpty) {
      _debugLogService?.info('$prefix len=0', tag: 'USB Serial');
      return;
    }
    _debugLogService?.info(
      '$prefix code=${bytes[0]} len=${bytes.length}',
      tag: 'USB Serial',
    );
  }
}

enum UsbSerialStatus { disconnected, connecting, connected, disconnecting }
