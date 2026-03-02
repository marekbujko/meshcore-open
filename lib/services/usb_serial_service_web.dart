import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import '../utils/usb_port_labels.dart';
import 'usb_serial_frame_codec.dart';

class UsbSerialService {
  UsbSerialService();

  static const Map<String, String> _knownUsbNames = <String, String>{
    '2886:1667': 'Seeed Wio Tracker L1',
  };
  static final Map<String, String> _deviceNamesByPortKey = <String, String>{};

  final StreamController<Uint8List> _frameController =
      StreamController<Uint8List>.broadcast();
  final UsbSerialFrameDecoder _frameDecoder = UsbSerialFrameDecoder();

  UsbSerialStatus _status = UsbSerialStatus.disconnected;
  JSObject? _port;
  JSObject? _reader;
  JSObject? _writer;
  String? _connectedPortName;
  String? _connectedPortKey;

  UsbSerialStatus get status => _status;
  String? get activePortName => _connectedPortName;
  Stream<Uint8List> get frameStream => _frameController.stream;
  bool get isConnected => _status == UsbSerialStatus.connected;

  JSObject get _navigator => JSObject.fromInteropObject(web.window.navigator);
  bool get _isSupported => _navigator.has('serial');
  JSObject? get _serial {
    if (!_isSupported) {
      return null;
    }
    final serial = _navigator['serial'];
    return serial == null ? null : serial as JSObject;
  }

  Future<List<String>> listPorts() async {
    if (!_isSupported) {
      return const <String>[];
    }

    final ports = await _getAuthorizedPorts();
    if (ports.isEmpty) {
      return const <String>[usbRequestPortLabel];
    }
    return ports.map(_displayLabelForPort).toList(growable: false);
  }

  Future<void> connect({
    required String portName,
    int baudRate = 115200,
  }) async {
    if (_status == UsbSerialStatus.connected ||
        _status == UsbSerialStatus.connecting) {
      throw StateError('USB serial transport is already active');
    }
    if (!_isSupported) {
      throw UnsupportedError('Web Serial is not supported by this browser.');
    }

    _status = UsbSerialStatus.connecting;

    try {
      final requestedPortName = normalizeUsbPortName(portName);
      final authorizedPorts = await _getAuthorizedPorts();
      _port = _selectPort(authorizedPorts, requestedPortName);

      _port ??= await _requestPort();
      if (_port == null) {
        throw StateError('No USB serial device selected');
      }

      await _openPort(_port!, baudRate);
      _connectedPortKey = _portKeyFor(_port!);
      _connectedPortName = _buildDisplayLabel(_connectedPortKey!);
      _writer = _getWriter(_port!);
      _reader = _getReader(_port!);
      _status = UsbSerialStatus.connected;
      unawaited(_pumpReads());

      debugPrint('USB serial opened port=$_connectedPortName via Web Serial');
    } catch (error) {
      await _cleanupFailedConnect();
      _status = UsbSerialStatus.disconnected;
      _connectedPortName = null;
      _connectedPortKey = null;
      rethrow;
    }
  }

  Future<void> write(Uint8List data) async {
    if (!isConnected || _writer == null) {
      throw StateError('USB serial port is not open');
    }

    final packet = wrapUsbSerialTxFrame(data);
    _logFrameSummary('USB TX frame', data);

    final promise = _writer!.callMethod<JSPromise<JSAny?>>(
      'write'.toJS,
      packet.toJS,
    );
    await promise.toDart;
  }

  Future<void> disconnect() async {
    if (_status == UsbSerialStatus.disconnected) return;

    _status = UsbSerialStatus.disconnecting;
    final reader = _reader;
    final writer = _writer;
    final port = _port;

    _reader = null;
    _writer = null;
    _port = null;
    _connectedPortName = null;
    _connectedPortKey = null;

    if (reader != null) {
      try {
        await reader.callMethod<JSPromise<JSAny?>>('cancel'.toJS).toDart;
      } catch (_) {
        // Ignore errors while closing.
      }
      _releaseLock(reader);
    }

    if (writer != null) {
      _releaseLock(writer);
    }

    if (port != null) {
      try {
        await port.callMethod<JSPromise<JSAny?>>('close'.toJS).toDart;
      } catch (_) {
        // Ignore errors while closing.
      }
    }

    _status = UsbSerialStatus.disconnected;
  }

  void updateConnectedLabel(String label) {
    final trimmed = label.trim();
    final portKey = _connectedPortKey;
    if (trimmed.isEmpty || portKey == null) {
      return;
    }
    _deviceNamesByPortKey[portKey] = trimmed;
    _connectedPortName = _buildDisplayLabel(portKey);
  }

  void dispose() {
    unawaited(disconnect());
    unawaited(_frameController.close());
  }

  Future<List<JSObject>> _getAuthorizedPorts() async {
    final serial = _serial;
    if (serial == null) {
      return const <JSObject>[];
    }
    final result = await serial
        .callMethod<JSPromise<JSAny?>>('getPorts'.toJS)
        .toDart;
    return _toObjectList(result);
  }

  Future<JSObject?> _requestPort() async {
    final serial = _serial;
    if (serial == null) {
      return null;
    }
    final result = await serial
        .callMethod<JSPromise<JSAny?>>('requestPort'.toJS)
        .toDart;
    return result == null ? null : result as JSObject;
  }

  JSObject? _selectPort(List<JSObject> ports, String requestedPortName) {
    if (ports.isEmpty) {
      return null;
    }
    if (requestedPortName.isEmpty || requestedPortName == usbRequestPortLabel) {
      return ports.first;
    }
    for (final port in ports) {
      final description = _describePort(port);
      if (description == requestedPortName) {
        return port;
      }
    }
    return null;
  }

  Future<void> _openPort(JSObject port, int baudRate) {
    final options = JSObject()..['baudRate'] = baudRate.toJS;
    return port.callMethod<JSPromise<JSAny?>>('open'.toJS, options).toDart;
  }

  Future<void> _cleanupFailedConnect() async {
    final reader = _reader;
    final writer = _writer;
    final port = _port;

    _reader = null;
    _writer = null;
    _port = null;

    if (reader != null) {
      try {
        await reader.callMethod<JSPromise<JSAny?>>('cancel'.toJS).toDart;
      } catch (_) {
        // Ignore cleanup errors after a failed connect.
      }
      _releaseLock(reader);
    }

    if (writer != null) {
      _releaseLock(writer);
    }

    if (port != null) {
      try {
        await port.callMethod<JSPromise<JSAny?>>('close'.toJS).toDart;
      } catch (_) {
        // Ignore cleanup errors after a failed connect.
      }
    }
  }

  JSObject? _getReader(JSObject port) {
    final readable = port.getProperty<JSAny?>('readable'.toJS);
    if (readable == null) {
      throw StateError('Web Serial port is not readable');
    }
    final readableObject = readable as JSObject;
    return readableObject.callMethod<JSAny?>('getReader'.toJS) as JSObject;
  }

  JSObject? _getWriter(JSObject port) {
    final writable = port.getProperty<JSAny?>('writable'.toJS);
    if (writable == null) {
      throw StateError('Web Serial port is not writable');
    }
    final writableObject = writable as JSObject;
    return writableObject.callMethod<JSAny?>('getWriter'.toJS) as JSObject;
  }

  Future<void> _pumpReads() async {
    final reader = _reader;
    if (reader == null) return;

    try {
      while (_status == UsbSerialStatus.connected &&
          identical(reader, _reader)) {
        final result = await reader
            .callMethod<JSPromise<JSAny?>>('read'.toJS)
            .toDart;
        if (result == null) {
          break;
        }
        final resultObject = result as JSObject;

        final doneValue = resultObject.getProperty<JSAny?>('done'.toJS);
        final done = doneValue != null && doneValue.dartify() == true;
        if (done) {
          break;
        }

        final value = resultObject.getProperty<JSAny?>('value'.toJS);
        final bytes = _coerceBytes(value);
        if (bytes != null && bytes.isNotEmpty) {
          _ingestRawBytes(bytes);
        }
      }
    } catch (error, stackTrace) {
      if (_status == UsbSerialStatus.connected) {
        _frameController.addError(error, stackTrace);
      }
    } finally {
      _releaseLock(reader);
      if (_status == UsbSerialStatus.connected && identical(reader, _reader)) {
        _frameController.addError(StateError('USB serial connection closed'));
      }
    }
  }

  Uint8List? _coerceBytes(JSAny? value) {
    if (value == null) return null;
    try {
      return (value as JSUint8Array).toDart;
    } catch (_) {
      // Fall back to array-like coercion below.
    }

    final object = value as JSObject;
    if (object.has('length')) {
      final lengthValue = object.getProperty<JSAny?>('length'.toJS)?.dartify();
      if (lengthValue is num) {
        final length = lengthValue.toInt();
        final bytes = Uint8List(length);
        for (var i = 0; i < length; i++) {
          final item = object.getProperty<JSAny?>(i.toString().toJS)?.dartify();
          if (item is num) {
            bytes[i] = item.toInt();
          }
        }
        return bytes;
      }
    }

    return null;
  }

  List<JSObject> _toObjectList(JSAny? value) {
    if (value == null) {
      return const <JSObject>[];
    }
    final object = value as JSObject;
    if (!object.has('length')) {
      return const <JSObject>[];
    }

    final lengthValue = object.getProperty<JSAny?>('length'.toJS)?.dartify();
    if (lengthValue is! num) {
      return const <JSObject>[];
    }

    final length = lengthValue.toInt();
    final items = <JSObject>[];
    for (var i = 0; i < length; i++) {
      final item = object.getProperty<JSAny?>(i.toString().toJS);
      if (item != null) {
        items.add(item as JSObject);
      }
    }
    return items;
  }

  String _describePort(JSObject port) {
    try {
      final info = port.callMethod<JSAny?>('getInfo'.toJS);
      if (info == null) {
        return usbRequestPortLabel;
      }
      final infoObject = info as JSObject;

      final vendorId = infoObject
          .getProperty<JSAny?>('usbVendorId'.toJS)
          ?.dartify();
      final productId = infoObject
          .getProperty<JSAny?>('usbProductId'.toJS)
          ?.dartify();
      final hasVendor = vendorId is num;
      final hasProduct = productId is num;

      return describeWebUsbPort(
        vendorId: hasVendor ? vendorId.toInt() : null,
        productId: hasProduct ? productId.toInt() : null,
        knownUsbNames: _knownUsbNames,
      );
    } catch (_) {
      return usbRequestPortLabel;
    }
  }

  String _portKeyFor(JSObject port) => _describePort(port);

  String _displayLabelForPort(JSObject port) =>
      _buildDisplayLabel(_portKeyFor(port));

  String _buildDisplayLabel(String portKey) {
    return buildUsbDisplayLabel(
      basePortLabel: portKey,
      deviceName: _deviceNamesByPortKey[portKey],
    );
  }

  void _releaseLock(JSObject resource) {
    try {
      resource.callMethod<JSAny?>('releaseLock'.toJS);
    } catch (_) {
      // Ignore lock release failures.
    }
  }

  void _ingestRawBytes(Uint8List bytes) {
    for (final packet in _frameDecoder.ingest(bytes)) {
      if (!packet.isRxFrame) {
        debugPrint(
          'USB ignored packet start=0x${packet.frameStart.toRadixString(16).padLeft(2, '0')} len=${packet.payload.length}',
        );
        continue;
      }
      _frameController.add(packet.payload);
    }
  }

  void _logFrameSummary(String prefix, Uint8List bytes) {
    if (bytes.isEmpty) {
      debugPrint('$prefix len=0');
      return;
    }
    debugPrint('$prefix code=${bytes[0]} len=${bytes.length}');
  }
}

enum UsbSerialStatus { disconnected, connecting, connected, disconnecting }
