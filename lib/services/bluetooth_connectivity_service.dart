import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

enum BluetoothStatus {
  on,
  off,
  unsupported,
  unauthorized,
  unknown,
}

enum BluetoothPermissionStatus {
  granted,
  denied,
  permanentlyDenied,
  unknown,
}

/// Centralized service for managing Bluetooth connectivity
class BluetoothConnectivityService {
  static final BluetoothConnectivityService _instance =
      BluetoothConnectivityService._internal();

  factory BluetoothConnectivityService() => _instance;

  BluetoothConnectivityService._internal();

  BluetoothStatus _currentStatus = BluetoothStatus.unknown;
  BluetoothPermissionStatus _permissionStatus = BluetoothPermissionStatus.unknown;

  BluetoothStatus get currentStatus => _currentStatus;
  BluetoothPermissionStatus get permissionStatus => _permissionStatus;

  /// Check if Bluetooth is available and enabled
  Future<BluetoothStatus> checkBluetoothStatus() async {
    try {
      // Check if Bluetooth is supported on this device
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) {
        _currentStatus = BluetoothStatus.unsupported;
        return _currentStatus;
      }

      // Get current adapter state
      final adapterState = await FlutterBluePlus.adapterState.first;

      switch (adapterState) {
        case BluetoothAdapterState.on:
          _currentStatus = BluetoothStatus.on;
          break;
        case BluetoothAdapterState.off:
          _currentStatus = BluetoothStatus.off;
          break;
        case BluetoothAdapterState.unauthorized:
          _currentStatus = BluetoothStatus.unauthorized;
          break;
        default:
          _currentStatus = BluetoothStatus.unknown;
      }

      return _currentStatus;
    } catch (e) {
      debugPrint('Error checking Bluetooth status: $e');
      _currentStatus = BluetoothStatus.unknown;
      return _currentStatus;
    }
  }

  /// Check and request Bluetooth permissions
  Future<BluetoothPermissionStatus> checkPermissions() async {
    try {
      if (Platform.isAndroid) {
        // For Android 12+ (API level 31+), we need BLUETOOTH_SCAN and BLUETOOTH_CONNECT
        final bluetoothScanPermission = await Permission.bluetoothScan.status;
        final bluetoothConnectPermission = await Permission.bluetoothConnect.status;
        
        debugPrint('Bluetooth Scan Permission: $bluetoothScanPermission');
        debugPrint('Bluetooth Connect Permission: $bluetoothConnectPermission');

        if (bluetoothScanPermission.isGranted && bluetoothConnectPermission.isGranted) {
          _permissionStatus = BluetoothPermissionStatus.granted;
        } else if (bluetoothScanPermission.isPermanentlyDenied || bluetoothConnectPermission.isPermanentlyDenied) {
          _permissionStatus = BluetoothPermissionStatus.permanentlyDenied;
        } else {
          _permissionStatus = BluetoothPermissionStatus.denied;
        }
      } else {
        // iOS permissions are handled automatically
        _permissionStatus = BluetoothPermissionStatus.granted;
      }

      return _permissionStatus;
    } catch (e) {
      debugPrint('Error checking Bluetooth permissions: $e');
      _permissionStatus = BluetoothPermissionStatus.unknown;
      return _permissionStatus;
    }
  }

  /// Request Bluetooth permissions
  Future<BluetoothPermissionStatus> requestPermissions() async {
    try {
      if (Platform.isAndroid) {
        // Request multiple permissions at once
        final permissions = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
        ].request();

        debugPrint('Permission request results: $permissions');

        final bluetoothScanStatus = permissions[Permission.bluetoothScan] ?? PermissionStatus.denied;
        final bluetoothConnectStatus = permissions[Permission.bluetoothConnect] ?? PermissionStatus.denied;

        if (bluetoothScanStatus.isGranted && bluetoothConnectStatus.isGranted) {
          _permissionStatus = BluetoothPermissionStatus.granted;
        } else if (bluetoothScanStatus.isPermanentlyDenied || bluetoothConnectStatus.isPermanentlyDenied) {
          _permissionStatus = BluetoothPermissionStatus.permanentlyDenied;
        } else {
          _permissionStatus = BluetoothPermissionStatus.denied;
        }
      } else {
        // iOS permissions are handled automatically
        _permissionStatus = BluetoothPermissionStatus.granted;
      }

      return _permissionStatus;
    } catch (e) {
      debugPrint('Error requesting Bluetooth permissions: $e');
      _permissionStatus = BluetoothPermissionStatus.unknown;
      return _permissionStatus;
    }
  }

  /// Request to turn on Bluetooth (Android only)
  Future<bool> requestBluetoothOn() async {
    try {
      if (Platform.isAndroid) {
        await FlutterBluePlus.turnOn();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error turning on Bluetooth: $e');
      return false;
    }
  }

  /// Check if we can start scanning
  bool canScan() {
    return _currentStatus == BluetoothStatus.on &&
        _permissionStatus == BluetoothPermissionStatus.granted;
  }

  /// Open device settings for permission management
  Future<bool> openSettings() async {
    try {
      return await openAppSettings();
    } catch (e) {
      debugPrint('Error opening app settings: $e');
      return false;
    }
  }

  /// Listen to Bluetooth adapter state changes
  Stream<BluetoothAdapterState> get adapterStateStream =>
      FlutterBluePlus.adapterState;
}
