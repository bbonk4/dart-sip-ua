import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import 'package:sip_ua/src/sip_ua_helper.dart';
import '../logger.dart';

typedef OnMessageCallback = void Function(dynamic msg);
typedef OnCloseCallback = void Function(int? code, String? reason);
typedef OnOpenCallback = void Function();

class SIPUAWebSocketImpl {
  SIPUAWebSocketImpl(this._url, this.messageDelay);

  final String _url;
  web.WebSocket? _socket;
  OnOpenCallback? onOpen;
  OnMessageCallback? onMessage;
  OnCloseCallback? onClose;
  final int messageDelay;
  
  // Message queue for handling message delay
  final StreamController<dynamic> _queue = StreamController<dynamic>.broadcast();
  StreamSubscription? _queueSubscription;

  void connect(
      {Iterable<String>? protocols,
      required WebSocketSettings webSocketSettings}) async {
    logger.i('connect $_url, ${webSocketSettings.extraHeaders}, $protocols');
    
    // Set up message queue handler
    _handleQueue();
    
    try {
      // Create WebSocket with 'sip' protocol
      _socket = web.WebSocket(_url, 'sip'.toJS);
      
      // Handle open event
      _socket!.addEventListener('open', ((web.Event e) {
        onOpen?.call();
      }).toJS);

      // Handle message event
      _socket!.addEventListener('message', ((web.Event event) {
        final messageEvent = event as web.MessageEvent;
        final data = messageEvent.data;
        
        // Check if data is a string
        if (data.typeofEquals('string')) {
          final strData = (data as JSString).toDart;
          onMessage?.call(strData);
        } else if (data.isA<web.Blob>()) {
          // If data is a Blob, we need to handle it asynchronously
          logger.d('Received Blob data, handling as text');
          final blob = data as web.Blob;
          // Create a FileReader to read the blob
          final reader = web.FileReader();
          reader.addEventListener('loadend', ((web.Event e) {
            final result = reader.result;
            if (result != null && result.typeofEquals('string')) {
              final strResult = (result as JSString).toDart;
              onMessage?.call(strResult);
            }
          }).toJS);
          reader.readAsText(blob);
        } else {
          // Handle other data types if needed
          logger.d('Received unknown data type');
        }
      }).toJS);

      // Handle close event
      _socket!.addEventListener('close', ((web.Event event) {
        final closeEvent = event as web.CloseEvent;
        onClose?.call(closeEvent.code, closeEvent.reason);
        _cleanup();
      }).toJS);
      
      // Handle error event
      _socket!.addEventListener('error', ((web.Event e) {
        logger.e('WebSocket error occurred');
        onClose?.call(0, 'WebSocket error');
        _cleanup();
      }).toJS);
    } catch (e) {
      onClose?.call(0, e.toString());
      _cleanup();
    }
  }

  void _handleQueue() {
    _queueSubscription = _queue.stream.asyncMap((dynamic event) async {
      // Add delay between messages if configured
      if (messageDelay > 0) {
        await Future<void>.delayed(Duration(milliseconds: messageDelay));
      }
      return event;
    }).listen((dynamic event) {
      // Actually send the message through the WebSocket
      if (_socket != null && _socket!.readyState == web.WebSocket.OPEN) {
        // Send data as-is (it's already a string from SIP layer)
        if (event is String) {
          _socket!.send(event.toJS);
        } else {
          _socket!.send((event as JSAny));
        }
        logger.d('send: \n\n$event');
      } else {
        logger.e('WebSocket not connected, message $event not sent');
      }
    });
  }

  void send(dynamic data) {
    // Add to queue instead of sending directly
    if (_socket != null) {
      _queue.add(data);
    } else {
      logger.e('WebSocket is null, message $data not sent');
    }
  }

  bool isConnecting() {
    return _socket != null && _socket!.readyState == web.WebSocket.CONNECTING;
  }

  void close() {
    _cleanup();
    _socket?.close();
  }
  
  void _cleanup() {
    _queueSubscription?.cancel();
    if (!_queue.isClosed) {
      _queue.close();
    }
  }
}