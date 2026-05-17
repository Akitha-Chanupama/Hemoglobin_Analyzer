// ignore_for_file: library_private_types_in_public_api, deprecated_member_use, use_build_context_synchronously

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../services/bluetooth_connectivity_service.dart';
import '../utils/flutter_state_ext.dart';

/// Data class to hold hemoglobin measurement
class HemoglobinMeasurement {
  final DateTime timestamp;
  final double? hemoglobin; // g/dL

  HemoglobinMeasurement({required this.timestamp, this.hemoglobin});
}

class HemoglobinMonitorPage extends StatefulWidget {
  final String? patientId;

  const HemoglobinMonitorPage({super.key, this.patientId});

  @override
  _HemoglobinMonitorPageState createState() => _HemoglobinMonitorPageState();
}

class _HemoglobinMonitorPageState extends State<HemoglobinMonitorPage>
    with TickerProviderStateMixin {
  // Colors
  static const Color _primaryRed = Color(0xFFB71C1C);
  static const Color _accentRed = Color(0xFFE53935);

  // Bluetooth service
  final BluetoothConnectivityService _bluetoothService =
      BluetoothConnectivityService();

  // Scan results
  final List<ScanResult> _scanResults = [];
  final List<ScanResult> _lysunDevices = [];

  // Connected device
  BluetoothDevice? _device;
  List<BluetoothService> _services = [];

  // States
  bool _isScanning = false;
  bool _isConnecting = false;
  bool _disposed = false;
  bool _hasConfirmedDeviceOn = false;
  bool _isTakingReading = false;

  // Animation controllers
  late AnimationController _pulseController;
  late AnimationController _slideController;

  // Stream subscriptions
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<bool>? _isScanningSubscription;
  StreamSubscription<List<int>>? _characteristicSubscription;

  // Measurement data
  String? hemoglobinValue;
  int? hctValue; // Hematocrit percentage

  // Buffer for partial data
  String _dataBuffer = '';

  // Write characteristics for sending commands
  BluetoothCharacteristic? _writeCharacteristic;

  // History data
  final List<HemoglobinMeasurement> _historyData = [];

  // Target device name for auto-connect
  // LYSUN BHM-101 is the Hemoglobin Analysis Meter
  static const String TARGET_DEVICE_NAME = "LYSUN BHM-101";

  @override
  void initState() {
    super.initState();

    // Initialize animation controllers
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();

    _slideController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    // Listen to scan results and filter for LYSUN devices
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (_disposed) return;

      setStateIfMounted(() {
        _scanResults.clear();
        _scanResults.addAll(results);
        _lysunDevices.clear();
        _lysunDevices.addAll(results.where((result) => _isLysunDevice(result)));
      });

      // Auto-connect to target device if found
      _autoConnectIfTargetFound(results);
    });

    // Listen to scanning state
    _isScanningSubscription = FlutterBluePlus.isScanning.listen((scanning) {
      if (_disposed) return;

      setStateIfMounted(() {
        _isScanning = scanning;
      });

      if (scanning) {
        _pulseController.repeat();
      } else {
        _pulseController.stop();
      }
    });

    // Initialize Bluetooth and show confirmation dialog
    _initBluetoothAndShowConfirmation();
  }

  Future<void> _initBluetoothAndShowConfirmation() async {
    await _initBluetooth();
    // Only show confirmation dialog if all permissions are granted
    final bluetoothStatus = await _bluetoothService.checkBluetoothStatus();
    final permissionStatus = await _bluetoothService.checkPermissions();

    if (mounted &&
        !_hasConfirmedDeviceOn &&
        bluetoothStatus == BluetoothStatus.on &&
        permissionStatus == BluetoothPermissionStatus.granted) {
      _showDeviceConfirmationDialog();
    }
  }

  void _showDeviceConfirmationDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(FontAwesomeIcons.droplet, color: _primaryRed, size: 24),
              const SizedBox(width: 12),
              Text(
                'Device Setup',
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.bold,
                  color: _primaryRed,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Before we scan for your Hemoglobin Meter, please ensure:',
                style: GoogleFonts.montserrat(
                  fontSize: 14,
                  color: Colors.grey[700],
                ),
              ),
              const SizedBox(height: 16),
              _buildChecklistItem(
                icon: Icons.power_settings_new,
                text: 'Device is turned ON',
              ),
              _buildChecklistItem(
                icon: Icons.bluetooth,
                text: 'Device Bluetooth is enabled',
              ),
              _buildChecklistItem(
                icon: Icons.phone_android,
                text: 'Phone Bluetooth is ON',
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Colors.amber.shade700,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Looking for: $TARGET_DEVICE_NAME',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.amber.shade900,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                setStateIfMounted(() {
                  _hasConfirmedDeviceOn = true;
                });
                _autoStartScanning();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _primaryRed,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Device is ON - Start Scan'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildChecklistItem({required IconData icon, required String text}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: _accentRed, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: GoogleFonts.montserrat(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Future<void> _initBluetooth() async {
    // Check Bluetooth status using centralized service
    final bluetoothStatus = await _bluetoothService.checkBluetoothStatus();
    final permissionStatus = await _bluetoothService.checkPermissions();

    if (bluetoothStatus == BluetoothStatus.unsupported) {
      _showBluetoothUnsupportedDialog();
      return;
    }

    if (permissionStatus != BluetoothPermissionStatus.granted) {
      // Request permissions
      final requestResult = await _bluetoothService.requestPermissions();

      if (requestResult == BluetoothPermissionStatus.permanentlyDenied) {
        // Show dialog to open app settings
        final settingsResult = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => _buildPermissionPermanentlyDeniedDialog(),
        );

        if (settingsResult == true) {
          await _bluetoothService.openSettings();
        }
        return;
      } else if (requestResult != BluetoothPermissionStatus.granted) {
        // Show dialog explaining permission requirement
        final result = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => _buildPermissionDialog(),
        );

        if (result != true) return;
      }
    }

    if (bluetoothStatus != BluetoothStatus.on) {
      // Show dialog to enable Bluetooth
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _buildEnableBluetoothDialog(),
      );

      if (result != true) return;
    }
  }

  void _showBluetoothUnsupportedDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red),
            SizedBox(width: 8),
            Text('Bluetooth Unsupported'),
          ],
        ),
        content: const Text(
          'This device does not support Bluetooth. Please use a device with Bluetooth capability.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionDialog() {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.bluetooth, color: _primaryRed),
          SizedBox(width: 8),
          Text('Bluetooth Permission Required'),
        ],
      ),
      content: const Text(
        'This app needs Bluetooth permissions to scan for and connect to the Hemoglobin Meter. Please grant the permission when requested.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () async {
            Navigator.of(context).pop(true);
            // Request permissions again
            await _bluetoothService.requestPermissions();
          },
          style: ElevatedButton.styleFrom(backgroundColor: _primaryRed),
          child: const Text(
            'Request Permission',
            style: TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _buildPermissionPermanentlyDeniedDialog() {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.warning, color: Colors.red),
          SizedBox(width: 8),
          Text('Permission Denied'),
        ],
      ),
      content: const Text(
        'Bluetooth permissions have been permanently denied. Please go to app settings and enable Bluetooth permissions manually to use this feature.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: ElevatedButton.styleFrom(backgroundColor: _primaryRed),
          child: const Text(
            'Open Settings',
            style: TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _buildEnableBluetoothDialog() {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.bluetooth_disabled, color: Colors.orange),
          SizedBox(width: 8),
          Text('Enable Bluetooth'),
        ],
      ),
      content: const Text(
        'Bluetooth is turned off. Please enable Bluetooth to connect to the Hemoglobin Meter.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () async {
            await _bluetoothService.requestBluetoothOn();
            Navigator.of(context).pop(true);
          },
          style: ElevatedButton.styleFrom(backgroundColor: _primaryRed),
          child: const Text('Enable', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }

  void _autoStartScanning() {
    debugPrint('🔄 _autoStartScanning called for Hemoglobin Monitor');
    debugPrint('  - mounted: $mounted');
    debugPrint('  - device connected: ${_device != null}');
    debugPrint('  - isScanning: $_isScanning');

    // Auto-start scanning after UI is ready
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted && _device == null && !_isScanning) {
        debugPrint('🔄 Starting auto-scan for Hemoglobin Monitor...');
        _startScan();
      }
    });
  }

  void _autoConnectIfTargetFound(List<ScanResult> results) {
    if (_disposed || _device != null || _isConnecting) return;

    // Look for LYSUN BHM-101 device
    for (var result in results) {
      // Try multiple ways to get the device name
      final deviceLocalName = result.device.localName;
      final advLocalName = result.advertisementData.localName;
      final platformName = result.device.platformName;
      final advName = result.advertisementData.advName;

      // Use whichever name is available
      String deviceName = '';
      if (deviceLocalName.isNotEmpty) {
        deviceName = deviceLocalName;
      } else if (advLocalName.isNotEmpty) {
        deviceName = advLocalName;
      } else if (platformName.isNotEmpty) {
        deviceName = platformName;
      } else if (advName.isNotEmpty) {
        deviceName = advName;
      }

      debugPrint(
        '🔍 Scan result - deviceLocalName: "$deviceLocalName", advLocalName: "$advLocalName", platformName: "$platformName", advName: "$advName"',
      );

      // Case-insensitive comparison with trimmed strings
      final normalizedDeviceName = deviceName.trim().toUpperCase();

      // Check if device name matches - ONLY match BHM-101 (Hemoglobin Meter)
      final isTargetDevice =
          normalizedDeviceName == TARGET_DEVICE_NAME.toUpperCase() ||
          normalizedDeviceName.contains('BHM-101') ||
          normalizedDeviceName.contains('BHM 101') ||
          normalizedDeviceName == 'BHM101' ||
          normalizedDeviceName.startsWith('BHM') ||
          // Only match LYSUN if it also contains BHM
          (normalizedDeviceName.contains('LYSUN') &&
              normalizedDeviceName.contains('BHM'));

      if (isTargetDevice && deviceName.isNotEmpty) {
        debugPrint('🎯 Found target device: $deviceName');
        debugPrint('🔌 Auto-connecting to $deviceName...');

        // Stop scanning and connect
        _connectToDevice(result.device);
        break;
      }
    }
  }

  // Helper method to identify LYSUN Hemoglobin Meter devices
  bool _isLysunDevice(ScanResult result) {
    // Get device name from multiple sources
    final deviceLocalName = result.device.localName.toLowerCase();
    final advLocalName = result.advertisementData.localName.toLowerCase();
    final platformName = result.device.platformName.toLowerCase();
    final advName = result.advertisementData.advName.toLowerCase();

    // Use whichever name is available
    String deviceName = '';
    if (deviceLocalName.isNotEmpty) {
      deviceName = deviceLocalName;
    } else if (advLocalName.isNotEmpty) {
      deviceName = advLocalName;
    } else if (platformName.isNotEmpty) {
      deviceName = platformName;
    } else if (advName.isNotEmpty) {
      deviceName = advName;
    }

    // Check for BHM-101 specifically (Hemoglobin Meter)
    return deviceName == TARGET_DEVICE_NAME.toLowerCase() ||
        deviceName.contains('bhm-101') ||
        deviceName.contains('bhm 101') ||
        deviceName == 'bhm101' ||
        deviceName.startsWith('bhm') ||
        // Only match LYSUN if it also contains BHM
        (deviceName.contains('lysun') && deviceName.contains('bhm')) ||
        // Check for known service UUIDs
        _hasLysunServiceUuids(result);
  }

  bool _hasLysunServiceUuids(ScanResult result) {
    // Check for known LYSUN service UUIDs in advertisement data
    final advertisementData = result.advertisementData;
    final serviceUuids = advertisementData.serviceUuids;

    // Add known LYSUN service UUIDs here (these may need to be updated based on actual device)
    const lysunServiceUuids = [
      'd44bc439-abfd-45a2-b575-925416129600',
      'd44bc439-abfd-45a2-b575-925416129601',
    ];

    return serviceUuids.any(
      (uuid) => lysunServiceUuids.contains(uuid.toString().toLowerCase()),
    );
  }

  @override
  void dispose() {
    _disposed = true;

    // Cancel subscriptions
    try {
      _scanResultsSubscription?.cancel();
    } catch (e) {
      debugPrint('Error canceling scan results subscription: $e');
    }

    try {
      _isScanningSubscription?.cancel();
    } catch (e) {
      debugPrint('Error canceling scanning subscription: $e');
    }

    try {
      _characteristicSubscription?.cancel();
    } catch (e) {
      debugPrint('Error canceling characteristic subscription: $e');
    }

    _pulseController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    debugPrint('🔍 _startScan called');

    // Double-check Bluetooth and permissions before scanning
    final bluetoothStatus = await _bluetoothService.checkBluetoothStatus();
    final permissionStatus = await _bluetoothService.checkPermissions();

    debugPrint('  - Bluetooth status: $bluetoothStatus');
    debugPrint('  - Permission status: $permissionStatus');

    if (bluetoothStatus != BluetoothStatus.on) {
      debugPrint('  - Bluetooth not on, showing enable dialog');
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _buildEnableBluetoothDialog(),
      );

      if (result != true) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Bluetooth not enabled')));
        return;
      }
    }

    if (permissionStatus != BluetoothPermissionStatus.granted) {
      debugPrint('  - Permissions not granted, requesting...');
      final requestResult = await _bluetoothService.requestPermissions();
      debugPrint('  - Permission request result: $requestResult');

      if (requestResult != BluetoothPermissionStatus.granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bluetooth permissions required')),
        );
        return;
      }
    }

    try {
      // Check if already scanning
      if (await FlutterBluePlus.isScanning.first) {
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Clear previous results
      if (!_disposed) {
        setStateIfMounted(() {
          _scanResults.clear();
          _lysunDevices.clear();
        });
      }

      debugPrint('  - Starting Bluetooth scan...');
      // Start scanning
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

      debugPrint("✅ Scan started successfully");
    } catch (e) {
      debugPrint("❌ Scan error: $e");
      if (!_disposed) {
        setStateIfMounted(() {
          _isScanning = false;
        });
      }

      // Show specific error to user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Scan failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
      debugPrint("Scan stopped");
    } catch (e) {
      debugPrint("Stop scan error: $e");
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_device != null) {
      debugPrint("Already connected to a device");
      return;
    }

    if (!_disposed) {
      setStateIfMounted(() {
        _isConnecting = true;
      });
    }

    debugPrint(
      "Connecting to ${device.name.isNotEmpty ? device.name : device.id.id}...",
    );

    try {
      // Stop scanning first
      await _stopScan();

      // Connect to device
      await device.connect(
        autoConnect: false,
        mtu: null,
        timeout: const Duration(seconds: 15),
      );

      if (!_disposed) {
        setStateIfMounted(() => _device = device);
      }
      debugPrint("Connected successfully!");
      _slideController.forward();

      // Discover services
      _services = await device.discoverServices();
      debugPrint("Discovered ${_services.length} services");

      // Setup characteristics
      await _setupCharacteristics();
    } catch (e) {
      debugPrint('Connection failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connection failed: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (!_disposed) {
        setStateIfMounted(() {
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _setupCharacteristics() async {
    BluetoothCharacteristic? notifyChar;
    BluetoothCharacteristic? writeChar;
    BluetoothCharacteristic? writeChar2;
    List<BluetoothCharacteristic> readableChars = [];

    for (var service in _services) {
      debugPrint('Service: ${service.uuid}');

      for (var characteristic in service.characteristics) {
        debugPrint('  Characteristic: ${characteristic.uuid}');
        debugPrint('  Properties: ${characteristic.properties}');

        try {
          // Skip standard device information characteristics (but NOT fff3)
          if (_isDeviceInfoCharacteristic(characteristic.uuid.toString()) &&
              characteristic.uuid.toString().toLowerCase() != 'fff3') {
            debugPrint('  -> Skipping device info characteristic');
            continue;
          }

          // Find notification characteristics for measurements
          // Check for LYSUN custom service UUID
          if (characteristic.uuid.toString() ==
              'd44bc439-abfd-45a2-b575-925416129601') {
            notifyChar = characteristic;
            await characteristic.setNotifyValue(true);
            debugPrint('  -> Measurement notifications enabled');

            _characteristicSubscription = characteristic.value.listen((value) {
              if (_disposed) return;
              debugPrint('Measurement notification received: $value');
              _parseTextMeasurement(value);
            });
          }

          // Also try to enable notifications on other notify characteristics
          if (characteristic.properties.notify &&
              notifyChar == null &&
              !_isDeviceInfoCharacteristic(characteristic.uuid.toString())) {
            try {
              await characteristic.setNotifyValue(true);
              debugPrint(
                '  -> Enabled notifications on: ${characteristic.uuid}',
              );

              _characteristicSubscription = characteristic.value.listen((
                value,
              ) {
                if (_disposed) return;
                debugPrint(
                  'Notification received from ${characteristic.uuid}: $value',
                );
                _parseTextMeasurement(value);
              });
              notifyChar = characteristic;
            } catch (e) {
              debugPrint('  -> Failed to enable notifications: $e');
            }
          }

          // Find write characteristics for sending commands
          if (characteristic.uuid.toString() ==
              'd44bc439-abfd-45a2-b575-925416129600') {
            writeChar = characteristic;
            _writeCharacteristic = characteristic; // Store for later use
            debugPrint('  -> Primary write characteristic found');
          }

          if (characteristic.uuid.toString() == 'ff01') {
            writeChar2 = characteristic;
            debugPrint('  -> Secondary write characteristic found');
          }

          // Also find other write characteristics
          if (characteristic.properties.write ||
              characteristic.properties.writeWithoutResponse) {
            if (writeChar == null) {
              writeChar = characteristic;
              _writeCharacteristic = characteristic; // Store for later use
              debugPrint(
                '  -> Found write characteristic: ${characteristic.uuid}',
              );
            } else if (writeChar2 == null) {
              writeChar2 = characteristic;
              debugPrint(
                '  -> Found secondary write characteristic: ${characteristic.uuid}',
              );
            }
          }

          // Collect readable characteristics to read stored data
          if (characteristic.properties.read) {
            readableChars.add(characteristic);
          }
        } catch (e) {
          debugPrint('  -> Setup failed for characteristic: $e');
        }
      }
    }

    // Store primary write characteristic
    if (writeChar != null) {
      _writeCharacteristic = writeChar;
    }

    // Try to read stored data from readable characteristics
    debugPrint('');
    debugPrint('📖 Reading stored data from readable characteristics...');
    for (var char in readableChars) {
      try {
        final value = await char.read();
        debugPrint('  📖 ${char.uuid}: $value');
        if (value.isNotEmpty) {
          debugPrint(
            '     Hex: ${value.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}',
          );
          try {
            String text = String.fromCharCodes(
              value.where((b) => b >= 32 && b <= 126),
            );
            if (text.isNotEmpty) {
              debugPrint('     ASCII: "$text"');
            }
          } catch (_) {}

          // Check if this might be measurement data
          _parseTextMeasurement(value);
        }
      } catch (e) {
        debugPrint('  📖 ${char.uuid}: Failed to read - $e');
      }
    }
    debugPrint('');

    // Try to trigger measurements
    await _requestMeasurements(writeChar, writeChar2);
  }

  bool _isDeviceInfoCharacteristic(String uuid) {
    // These are standard BLE device information characteristics
    final deviceInfoUuids = [
      '2a00', // Device Name
      '2a01', // Appearance
      '2a04', // Peripheral Preferred Connection Parameters
      '2a05', // Service Changed
      '2a23', // System ID
      '2a24', // Model Number String
      '2a25', // Serial Number String
      '2a26', // Firmware Revision String
      '2a27', // Hardware Revision String
      '2a28', // Software Revision String
      '2a29', // Manufacturer Name String
      '2a2a', // IEEE 11073-20601 Regulatory Cert
      '2a50', // PnP ID
      // Note: fff3 might contain measurement data, don't skip it
    ];
    return deviceInfoUuids.contains(uuid.toLowerCase());
  }

  Future<void> _requestMeasurements(
    BluetoothCharacteristic? writeChar,
    BluetoothCharacteristic? writeChar2,
  ) async {
    if (writeChar == null && writeChar2 == null) {
      debugPrint('No write characteristic available');
      return;
    }

    // BHM-101 Protocol Commands - trying many variations
    // Based on LYSUN device protocol: Start(0x2A/*) + Data + End(0x23/#)
    //
    // Packet structure appears to be: [0x2A, length, cmd, data..., checksum, 0x23]
    // Status packets have cmd=1, measurement packets likely have cmd=2,3,4,etc
    //
    // For requesting stored data, we need to find the correct command
    final commands = [
      // Basic read commands with different cmd values
      [0x2A, 0x04, 0x02, 0x06, 0x23], // cmd=2: Read measurement
      [0x2A, 0x04, 0x03, 0x07, 0x23], // cmd=3: Read memory
      [0x2A, 0x04, 0x04, 0x00, 0x23], // cmd=4: Read history
      [0x2A, 0x04, 0x05, 0x01, 0x23], // cmd=5: Get last result
      // Commands with data byte specifying record number
      [0x2A, 0x05, 0x02, 0x01, 0x06, 0x23], // Read record 1
      [0x2A, 0x05, 0x02, 0x00, 0x07, 0x23], // Read record 0
      [0x2A, 0x05, 0x03, 0x01, 0x07, 0x23], // Read memory slot 1
      // Alternative command formats
      [0x2A, 0x06, 0x00, 0x23], // Simple request
      [0x2A, 0x52, 0x23], // 'R' = Read command (ASCII)
      [0x2A, 0x4D, 0x23], // 'M' = Measure command (ASCII)
      [0x2A, 0x48, 0x23], // 'H' = History command (ASCII)
      [0x2A, 0x44, 0x23], // 'D' = Data command (ASCII)
      // XOR checksum variations for cmd=2 (read measurement)
      // Format: [0x2A, len, cmd, data, checksum(XOR), 0x23]
      [
        0x2A,
        0x05,
        0x02,
        0x00,
        0x07,
        0x23,
      ], // len=5, cmd=2, data=0, check=5^2^0=7
      [
        0x2A,
        0x05,
        0x02,
        0x01,
        0x06,
        0x23,
      ], // len=5, cmd=2, data=1, check=5^2^1=6
      // Original commands
      [0x2A, 0x01, 0x00, 0x01, 0x23], // Original request
      [0x2A, 0x02, 0x00, 0x02, 0x23], // Original last reading
      [0x2A, 0x03, 0x00, 0x03, 0x23], // Original stored data
    ];

    debugPrint(
      'Attempting to trigger measurements with ${commands.length} commands...',
    );

    for (int i = 0; i < commands.length; i++) {
      final command = commands[i];
      debugPrint('Trying command ${i + 1}/${commands.length}: $command');
      debugPrint(
        '  Hex: ${command.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}',
      );

      try {
        if (writeChar != null) {
          if (writeChar.properties.writeWithoutResponse) {
            await writeChar.write(command, withoutResponse: true);
          } else if (writeChar.properties.write) {
            await writeChar.write(command);
          }
          // Wait longer to see response
          await Future.delayed(const Duration(milliseconds: 500));
        }

        // Also try the secondary write characteristic
        if (writeChar2 != null && writeChar2 != writeChar) {
          try {
            if (writeChar2.properties.writeWithoutResponse) {
              await writeChar2.write(command, withoutResponse: true);
            } else if (writeChar2.properties.write) {
              await writeChar2.write(command);
            }
            await Future.delayed(const Duration(milliseconds: 300));
          } catch (e) {
            // Ignore errors on secondary
          }
        }
      } catch (e) {
        debugPrint('  -> Command failed: $e');
      }
    }
  }

  // Buffer for accumulating binary data
  List<int> _binaryBuffer = [];

  // Buffer for accumulating text data across multiple notifications
  String _textBuffer = '';

  void _parseTextMeasurement(List<int> val) {
    if (val.isEmpty) {
      debugPrint('⚠️ Empty notification received');
      return;
    }

    debugPrint('');
    debugPrint('═══════════════════════════════════════════════════════════');
    debugPrint('📦 NEW DATA RECEIVED (${val.length} bytes)');
    debugPrint('📦 Raw bytes: $val');
    debugPrint(
      '📦 Hex: ${val.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}',
    );

    // Try to interpret as ASCII text
    String asciiText = '';
    try {
      asciiText = String.fromCharCodes(val);
      String printableText = asciiText
          .replaceAll('\r', '\\r')
          .replaceAll('\n', '\\n');
      debugPrint('📦 ASCII: "$printableText"');
    } catch (_) {}

    // Check if this looks like TEXT data (contains readable characters like HB:, HCT:, ID:)
    bool isTextData =
        asciiText.contains('HB:') ||
        asciiText.contains('HCT:') ||
        asciiText.contains('ID:') ||
        asciiText.contains('g/dL') ||
        asciiText.contains('%') ||
        _textBuffer.isNotEmpty; // Continue accumulating if we started

    // Check if this is a binary packet (starts with 0x2A and ends with 0x23)
    bool isBinaryPacket =
        val.isNotEmpty && val[0] == 0x2A && val.contains(0x23);

    if (isTextData && !isBinaryPacket) {
      // Handle TEXT-based measurement data
      debugPrint('📝 TEXT DATA detected - adding to text buffer');
      _textBuffer += asciiText;

      // Try to parse the accumulated text buffer
      _parseAccumulatedText();
      return;
    }

    // Show decimal interpretations of each byte for binary data
    debugPrint('📦 Decimal values:');
    for (int i = 0; i < val.length; i++) {
      int b = val[i];
      String marker = '';
      if (b == 0x2A) marker = ' <- START (*)';
      if (b == 0x23) marker = ' <- END (#)';
      if (b >= 50 && b <= 250)
        marker += ' <- possible Hb*10 (${(b / 10).toStringAsFixed(1)} g/dL)';
      debugPrint(
        '    [$i]: $b (0x${b.toRadixString(16).padLeft(2, '0')})$marker',
      );
    }
    debugPrint('═══════════════════════════════════════════════════════════');
    debugPrint('');

    // Add to binary buffer
    _binaryBuffer.addAll(val);

    // Process complete packets (start with 0x2A/42/* and end with 0x23/35/#)
    _processBinaryBuffer();
  }

  /// Parse accumulated text data for measurements
  /// Expected format: "ID:798\r\nHB:16.5 g/dL\r\nHCT:48%\r\n2026-1-28 12:36\r\n"
  void _parseAccumulatedText() {
    debugPrint(
      '📝 Text buffer content: "${_textBuffer.replaceAll('\r', '\\r').replaceAll('\n', '\\n')}"',
    );

    double? hbValue;
    int? hctValueParsed;
    String? recordId;
    String? timestamp;

    // Parse HB value: "HB:16.5 g/dL" or "HB:16.5"
    RegExp hbRegex = RegExp(
      r'HB[:\s]*(\d+\.?\d*)\s*(g/dL)?',
      caseSensitive: false,
    );
    var hbMatch = hbRegex.firstMatch(_textBuffer);
    if (hbMatch != null) {
      String hbStr = hbMatch.group(1)!;
      hbValue = double.tryParse(hbStr);
      debugPrint('✅ Parsed HB: $hbValue g/dL');
    }

    // Parse HCT value: "HCT:48%" or "HCT:48"
    RegExp hctRegex = RegExp(r'HCT[:\s]*(\d+)\s*%?', caseSensitive: false);
    var hctMatch = hctRegex.firstMatch(_textBuffer);
    if (hctMatch != null) {
      String hctStr = hctMatch.group(1)!;
      hctValueParsed = int.tryParse(hctStr);
      debugPrint('✅ Parsed HCT: $hctValueParsed%');
    }

    // Parse ID: "ID:798"
    RegExp idRegex = RegExp(r'ID[:\s]*(\d+)', caseSensitive: false);
    var idMatch = idRegex.firstMatch(_textBuffer);
    if (idMatch != null) {
      recordId = idMatch.group(1);
      debugPrint('✅ Parsed ID: $recordId');
    }

    // Parse timestamp: "2026-1-28 12:36" (various formats)
    RegExp timestampRegex = RegExp(r'(\d{4}-\d{1,2}-\d{1,2}\s+\d{1,2}:\d{2})');
    var tsMatch = timestampRegex.firstMatch(_textBuffer);
    if (tsMatch != null) {
      timestamp = tsMatch.group(1);
      debugPrint('✅ Parsed Timestamp: $timestamp');
    }

    // If we have at least HB value, update the UI
    if (hbValue != null && hbValue >= 3.0 && hbValue <= 25.0) {
      debugPrint('🎉 VALID MEASUREMENT EXTRACTED FROM TEXT!');
      debugPrint('   HB: ${hbValue.toStringAsFixed(1)} g/dL');
      if (hctValueParsed != null) {
        debugPrint('   HCT: $hctValueParsed%');
      }
      if (recordId != null) {
        debugPrint('   Record ID: $recordId');
      }
      if (timestamp != null) {
        debugPrint('   Timestamp: $timestamp');
      }

      _lastRawPacket = _textBuffer.codeUnits;

      // Use the existing method to update the hemoglobin value
      _updateHemoglobinValue(hbValue, hctValue: hctValueParsed);

      // Clear text buffer after successful parse
      _textBuffer = '';

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Measurement received: ${hbValue.toStringAsFixed(1)} g/dL' +
                (hctValueParsed != null ? ', HCT: $hctValueParsed%' : ''),
          ),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    // Clear text buffer if it gets too large (over 500 chars) without valid data
    if (_textBuffer.length > 500) {
      debugPrint('⚠️ Text buffer too large, clearing');
      _textBuffer = '';
    }
  }

  void _processBinaryBuffer() {
    while (_binaryBuffer.isNotEmpty) {
      // Find start marker (0x2A = 42 = '*')
      int startIndex = _binaryBuffer.indexOf(0x2A);
      if (startIndex == -1) {
        // No start marker found, clear buffer
        _binaryBuffer.clear();
        return;
      }

      // Remove any data before start marker
      if (startIndex > 0) {
        _binaryBuffer = _binaryBuffer.sublist(startIndex);
      }

      // Find end marker (0x23 = 35 = '#')
      int endIndex = _binaryBuffer.indexOf(0x23);
      if (endIndex == -1) {
        // No complete packet yet, wait for more data
        return;
      }

      // Extract complete packet
      List<int> packet = _binaryBuffer.sublist(0, endIndex + 1);
      _binaryBuffer = _binaryBuffer.sublist(endIndex + 1);

      debugPrint('📦 Complete packet: $packet');
      debugPrint(
        '📦 Packet hex: ${packet.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}',
      );

      // Parse the packet
      _parseBinaryPacket(packet);
    }
  }

  void _parseBinaryPacket(List<int> packet) {
    // Packet format: [0x2A, data..., 0x23]
    // Remove start and end markers
    if (packet.length < 3) {
      debugPrint('⚠️ Packet too short: $packet');
      return;
    }

    List<int> data = packet.sublist(1, packet.length - 1);
    debugPrint('📊 Data bytes: $data');
    debugPrint(
      '📊 Data hex: ${data.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}',
    );

    // LYSUN BHM-101 Protocol Analysis:
    // Packet: [0x2A, length, cmd, data..., checksum, 0x23]
    // Status packets: [0x2A, 0x05, 0x01, status, checksum, 0x23] - length=5, cmd=1
    // Measurement packets likely have different cmd or longer length

    // For 16.5 g/dL, expect value 165 (x10) or 1650 (x100)
    // 165 = 0xA5, 1650 = 0x672

    if (data.length >= 2) {
      int length = data[0];
      int cmd = data[1];

      debugPrint('  📋 Packet info:');
      debugPrint('    Length byte: $length');
      debugPrint('    Command/Type: $cmd');

      // LYSUN BHM-101 Protocol:
      // Status packets: [0x2A, 0x05, 0x01, status, checksum, 0x23] - cmd=1
      // The device sends TEXT data for actual measurements (HB:16.5 g/dL, HCT:48%)
      // Binary packets are ONLY used for status updates

      // Skip malformed packets where cmd is the START marker (0x2A/42)
      // This happens when multiple status packets overlap
      if (cmd == 0x2A || cmd == 0x23) {
        debugPrint(
          '    ⚠️ MALFORMED PACKET - cmd is a marker byte (0x${cmd.toRadixString(16)})',
        );
        debugPrint('    ℹ️ Skipping malformed packet');
        return;
      }

      // CMD=1 is a STATUS packet - DO NOT extract hemoglobin from it
      if (cmd == 1) {
        if (data.length >= 3) {
          int status = data[2];
          String statusText = _getStatusText(status);
          debugPrint(
            '    📡 STATUS PACKET - Device status: $statusText (code: $status)',
          );
          debugPrint(
            '    ℹ️ Ignoring status packet - waiting for measurement packet',
          );
        }
        _lastRawPacket = packet;
        return; // Don't process status packets as measurements
      }

      // For non-status packets (cmd != 1), this is unexpected since
      // the device sends measurements as TEXT, not binary
      debugPrint('  ⚠️ UNEXPECTED BINARY PACKET (cmd=$cmd)');
      debugPrint(
        '  ℹ️ Device sends measurements as TEXT, ignoring binary packet',
      );
      return; // Skip binary parsing since measurements are text-based
    }
  }

  String _getStatusText(int status) {
    switch (status) {
      case 0:
        return 'Idle';
      case 1:
        return 'Ready/Waiting';
      case 2:
        return 'Measuring';
      case 3:
        return 'Processing';
      case 4:
        return 'Complete';
      case 5:
        return 'Error';
      default:
        return 'Unknown';
    }
  }

  List<int>? _lastRawPacket;

  void _updateHemoglobinValue(double value, {int? hctValue}) {
    if (!_disposed) {
      setStateIfMounted(() {
        hemoglobinValue = value.toStringAsFixed(1);
        if (hctValue != null) {
          this.hctValue = hctValue;
        }
        _addToHistory();
      });
    }
    debugPrint('📊 Updated hemoglobin display: $hemoglobinValue g/dL');
    if (hctValue != null) {
      debugPrint('📊 Updated HCT display: $hctValue%');
    }
  }

  void _parseTextLine(String line) {
    // Parse hemoglobin measurement (text-based fallback)
    // Format may vary - adjust based on actual device output
    // Common formats: "HB: 12.5 g/dL", "HGB 12.5", "Hb=12.5"
    if (!_disposed) {
      setStateIfMounted(() {
        if (line.toUpperCase().startsWith('HB') ||
            line.toUpperCase().startsWith('HGB') ||
            line.toUpperCase().contains('HEMOGLOBIN')) {
          hemoglobinValue = _extractValue(line);
        }
        // Also try to parse if the line contains just a number (some devices send raw values)
        else if (RegExp(r'^\d+\.?\d*$').hasMatch(line.trim())) {
          hemoglobinValue = line.trim();
        }
      });
    }

    debugPrint('Updated measurement:');
    debugPrint('  Hemoglobin: $hemoglobinValue g/dL');

    // Add to history if we have a valid value
    if (hemoglobinValue != null && hemoglobinValue != "N/A") {
      _addToHistory();
    }
  }

  String _extractValue(String line) {
    // Remove the parameter name and extract the value
    String value = line;

    // Remove common prefixes
    value = value.replaceAll(
      RegExp(r'^(HB|HGB|HEMOGLOBIN|Hb|Hgb)\s*[:\s=]+', caseSensitive: false),
      '',
    );

    // Remove common suffixes like "g/dL", "g/L", etc.
    value = value.replaceAll(RegExp(r'\s*(g/dL|g/L|mg/dL|%)\s*$'), '');

    // Trim whitespace
    value = value.trim();

    // If it's empty, return the original line
    if (value.isEmpty) return line;

    return value;
  }

  void _addToHistory() {
    final now = DateTime.now();

    double? hb;
    try {
      if (hemoglobinValue != null &&
          hemoglobinValue != "Low" &&
          hemoglobinValue != "High") {
        hb = double.tryParse(hemoglobinValue!);
      }
    } catch (e) {
      debugPrint('Error parsing hemoglobin value: $e');
    }

    if (hb != null) {
      if (!_disposed) {
        setStateIfMounted(() {
          _historyData.add(
            HemoglobinMeasurement(timestamp: now, hemoglobin: hb),
          );
        });
      }
    }
  }

  // Take a new reading from the device
  Future<void> _takeReading() async {
    if (_device == null || _writeCharacteristic == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Device not connected or not ready'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setStateIfMounted(() {
      _isTakingReading = true;
      _binaryBuffer.clear(); // Clear previous binary data
      _textBuffer = ''; // Clear previous text data
    });

    debugPrint('📤 Taking new reading...');

    try {
      // Send request measurement command
      // [42, 2, 0, 2, 35] is the command that retrieves stored measurement as TEXT
      // This returns: "ID:xxx\r\nHB:xx.x g/dL\r\nHCT:xx%\r\nYYYY-MM-DD HH:MM\r\n"
      final command = [0x2A, 0x02, 0x00, 0x02, 0x23];

      debugPrint('📤 Sending measurement request command: $command');
      try {
        if (_writeCharacteristic!.properties.writeWithoutResponse) {
          await _writeCharacteristic!.write(command, withoutResponse: true);
        } else {
          await _writeCharacteristic!.write(command);
        }
      } catch (e) {
        debugPrint('  -> Command failed: $e');
      }

      // Wait for response
      await Future.delayed(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('❌ Error taking reading: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      setStateIfMounted(() {
        _isTakingReading = false;
      });
    }
  }

  // Clear the current reading
  void _clearReading() {
    setStateIfMounted(() {
      hemoglobinValue = null;
      hctValue = null;
      _binaryBuffer.clear();
      _textBuffer = '';
      _dataBuffer = '';
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Reading cleared'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  // Save the current reading
  void _saveReading() {
    if (hemoglobinValue == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No reading to save'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Here you would typically save to a database or API
    // For now, we'll just show a confirmation
    final savedValue = hemoglobinValue;
    final timestamp = DateTime.now();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved: $savedValue g/dL at ${_formatTime(timestamp)}'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );

    debugPrint('💾 Saved reading: $savedValue g/dL at $timestamp');

    // Optionally clear after saving
    // _clearReading();
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _disconnect() async {
    if (_device != null) {
      try {
        await _device!.disconnect();
        debugPrint('Disconnected from device');
      } catch (e) {
        debugPrint('Disconnect error: $e');
      }

      if (!_disposed) {
        setStateIfMounted(() {
          _device = null;
          _services = [];
          _writeCharacteristic = null;
          hemoglobinValue = null;
          _dataBuffer = '';
          _binaryBuffer.clear();
        });
      }

      _slideController.reverse();
    }
  }

  // Get hemoglobin status based on value
  String _getHemoglobinStatus(String? value) {
    if (value == null || value == "N/A" || value == "--") return "No Data";
    if (value == "Low" || value == "High") return value;

    try {
      final numValue = double.parse(value);

      // Normal ranges (general adult reference)
      // Men: 13.5-17.5 g/dL, Women: 12.0-15.5 g/dL
      // Using average range for simplicity
      if (numValue < 10.0) return "Low";
      if (numValue < 12.0) return "Borderline Low";
      if (numValue <= 17.5) return "Normal";
      if (numValue <= 20.0) return "Borderline High";
      return "High";
    } catch (e) {
      return "Unknown";
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case "Normal":
        return Colors.green;
      case "Borderline Low":
      case "Borderline High":
        return Colors.orange;
      case "High":
      case "Low":
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        backgroundColor: _primaryRed,
        foregroundColor: Colors.white,
        title: Text(
          'Hemoglobin Monitor',
          style: GoogleFonts.montserrat(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        actions: [
          if (_device != null)
            IconButton(
              icon: const Icon(Icons.bluetooth_disabled),
              onPressed: _disconnect,
              tooltip: 'Disconnect',
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 16),
              _buildConnectionStatus(),
              const SizedBox(height: 16),
              if (_device != null) ...[
                _buildSectionTitle(
                  icon: FontAwesomeIcons.droplet,
                  title: 'Measurement',
                ),
                const SizedBox(height: 8),
                _buildMeasurementCard(),
                const SizedBox(height: 16),
                // History section
                if (_historyData.isNotEmpty) ...[
                  _buildSectionTitle(
                    icon: Icons.history,
                    title: 'Recent Readings',
                  ),
                  const SizedBox(height: 8),
                  _buildHistoryList(),
                  const SizedBox(height: 16),
                ],
              ],
              if (_device == null) ...[
                _buildSectionTitle(
                  icon: Icons.bluetooth_searching,
                  title: 'Available Devices',
                ),
                const SizedBox(height: 8),
                _buildScanningSection(),
              ],
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryList() {
    // Show last 5 readings, newest first
    final recentReadings = _historyData.reversed.take(5).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: recentReadings.length,
          separatorBuilder: (context, index) =>
              Divider(height: 1, color: Colors.grey[200]),
          itemBuilder: (context, index) {
            final reading = recentReadings[index];
            final status = _getHemoglobinStatus(
              reading.hemoglobin?.toStringAsFixed(1),
            );
            final statusColor = _getStatusColor(status);

            return ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  FontAwesomeIcons.droplet,
                  color: statusColor,
                  size: 18,
                ),
              ),
              title: Text(
                '${reading.hemoglobin?.toStringAsFixed(1) ?? '--'} g/dL',
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              subtitle: Text(
                _formatDateTime(reading.timestamp),
                style: GoogleFonts.montserrat(
                  fontSize: 12,
                  color: Colors.grey[600],
                ),
              ),
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  status,
                  style: GoogleFonts.montserrat(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: statusColor,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dateTime.year, dateTime.month, dateTime.day);

    String timeStr =
        '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';

    if (date == today) {
      return 'Today at $timeStr';
    } else if (date == today.subtract(const Duration(days: 1))) {
      return 'Yesterday at $timeStr';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year} at $timeStr';
    }
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_primaryRed, _accentRed],
        ),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  FontAwesomeIcons.droplet,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LYSUN BHM-101',
                      style: GoogleFonts.montserrat(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Hemoglobin Analysis Meter',
                      style: GoogleFonts.montserrat(
                        fontSize: 14,
                        color: Colors.white.withOpacity(0.9),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStatus() {
    final isConnected = _device != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isConnected
                      ? Colors.green.withOpacity(0.1)
                      : Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                  color: isConnected ? Colors.green : Colors.orange,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isConnected ? 'Connected' : 'Not Connected',
                      style: GoogleFonts.montserrat(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: isConnected ? Colors.green : Colors.orange,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isConnected
                          ? _device!.name.isNotEmpty
                                ? _device!.name
                                : _device!.id.id
                          : 'Searching for device...',
                      style: GoogleFonts.montserrat(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
              if (_isConnecting)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(_primaryRed),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle({required IconData icon, required String title}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(icon, color: _primaryRed, size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: GoogleFonts.montserrat(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey[800],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMeasurementCard() {
    final status = _getHemoglobinStatus(hemoglobinValue);
    final statusColor = _getStatusColor(status);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.white, statusColor.withOpacity(0.05)],
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _primaryRed.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      FontAwesomeIcons.droplet,
                      color: _primaryRed,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hemoglobin',
                          style: GoogleFonts.montserrat(
                            fontSize: 14,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              hemoglobinValue ?? '--',
                              style: GoogleFonts.montserrat(
                                fontSize: 36,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey[800],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                'g/dL',
                                style: GoogleFonts.montserrat(
                                  fontSize: 16,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ),
                          ],
                        ),
                        // HCT Value display
                        if (hctValue != null) ...[
                          const SizedBox(height: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                'HCT: ',
                                style: GoogleFonts.montserrat(
                                  fontSize: 14,
                                  color: Colors.grey[600],
                                ),
                              ),
                              Text(
                                '$hctValue',
                                style: GoogleFonts.montserrat(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey[800],
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '%',
                                style: GoogleFonts.montserrat(
                                  fontSize: 14,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: statusColor.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      status == "Normal"
                          ? Icons.check_circle
                          : status.contains("Borderline")
                          ? Icons.warning
                          : Icons.info,
                      color: statusColor,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      status,
                      style: GoogleFonts.montserrat(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Reference ranges
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Text(
                      'Normal Ranges',
                      style: GoogleFonts.montserrat(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildRangeItem('Men', '13.5-17.5'),
                        Container(
                          height: 30,
                          width: 1,
                          color: Colors.grey[300],
                        ),
                        _buildRangeItem('Women', '12.0-15.5'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Take Reading Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isTakingReading ? null : _takeReading,
                  icon: _isTakingReading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Colors.white),
                          ),
                        )
                      : const Icon(FontAwesomeIcons.droplet, size: 18),
                  label: Text(
                    _isTakingReading ? 'Reading...' : 'Take Reading',
                    style: GoogleFonts.montserrat(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryRed,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              if (hemoglobinValue != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _clearReading,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: Text(
                          'Clear',
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.grey[700],
                          side: BorderSide(color: Colors.grey[400]!),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _saveReading,
                        icon: const Icon(Icons.save, size: 18),
                        label: Text(
                          'Save',
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRangeItem(String label, String range) {
    return Column(
      children: [
        Text(
          label,
          style: GoogleFonts.montserrat(fontSize: 11, color: Colors.grey[600]),
        ),
        const SizedBox(height: 2),
        Text(
          '$range g/dL',
          style: GoogleFonts.montserrat(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.grey[800],
          ),
        ),
      ],
    );
  }

  Widget _buildScanningSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // Scan button
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: InkWell(
              onTap: _isScanning ? _stopScan : _startScan,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    if (_isScanning)
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) {
                          return Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: _primaryRed.withOpacity(
                                0.1 + (_pulseController.value * 0.2),
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.bluetooth_searching,
                              color: _primaryRed,
                              size: 24,
                            ),
                          );
                        },
                      )
                    else
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _primaryRed.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.bluetooth_searching,
                          color: _primaryRed,
                          size: 24,
                        ),
                      ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isScanning ? 'Scanning...' : 'Scan for Devices',
                            style: GoogleFonts.montserrat(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[800],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _isScanning
                                ? 'Looking for $TARGET_DEVICE_NAME'
                                : 'Tap to search for nearby devices',
                            style: GoogleFonts.montserrat(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_isScanning)
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(_primaryRed),
                        ),
                      )
                    else
                      Icon(
                        Icons.arrow_forward_ios,
                        color: Colors.grey[400],
                        size: 16,
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Device list
          if (_lysunDevices.isNotEmpty) ...[
            ...(_lysunDevices.map((result) => _buildDeviceCard(result))),
          ] else if (_scanResults.isNotEmpty) ...[
            _buildNoLysunDevicesMessage(),
            const SizedBox(height: 8),
            Text(
              'Other Bluetooth devices found:',
              style: GoogleFonts.montserrat(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            ...(_scanResults.take(5).map((result) => _buildDeviceCard(result))),
          ] else if (!_isScanning) ...[
            _buildNoDevicesMessage(),
          ],
        ],
      ),
    );
  }

  Widget _buildNoLysunDevicesMessage() {
    return Card(
      elevation: 1,
      color: Colors.orange[50],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange[700], size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Target Device Not Found',
                    style: GoogleFonts.montserrat(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange[800],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Make sure $TARGET_DEVICE_NAME is turned on and in pairing mode.',
                    style: GoogleFonts.montserrat(
                      fontSize: 12,
                      color: Colors.orange[700],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoDevicesMessage() {
    return Card(
      elevation: 1,
      color: Colors.grey[200],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.bluetooth_disabled, color: Colors.grey[500], size: 48),
            const SizedBox(height: 16),
            Text(
              'No Devices Found',
              style: GoogleFonts.montserrat(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.grey[700],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap "Scan for Devices" to search for nearby Bluetooth devices.',
              style: GoogleFonts.montserrat(
                fontSize: 13,
                color: Colors.grey[600],
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCard(ScanResult result) {
    final deviceName = result.device.name.isNotEmpty
        ? result.device.name
        : result.device.platformName.isNotEmpty
        ? result.device.platformName
        : result.device.id.id;
    final signalStrength = result.rssi;
    final isStrongSignal = signalStrength > -70;
    final isTargetDevice = _isLysunDevice(result);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        elevation: isTargetDevice ? 3 : 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: isTargetDevice
              ? BorderSide(color: _primaryRed, width: 2)
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: () => _connectToDevice(result.device),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isTargetDevice
                        ? _primaryRed.withOpacity(0.1)
                        : Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isTargetDevice ? FontAwesomeIcons.droplet : Icons.bluetooth,
                    color: isTargetDevice ? _primaryRed : Colors.blue,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              deviceName,
                              style: GoogleFonts.montserrat(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[800],
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isTargetDevice)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: _primaryRed,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                'Target',
                                style: GoogleFonts.montserrat(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            isStrongSignal
                                ? Icons.signal_cellular_4_bar
                                : Icons.signal_cellular_alt_2_bar,
                            color: isStrongSignal
                                ? Colors.green
                                : Colors.orange,
                            size: 14,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$signalStrength dBm',
                            style: GoogleFonts.montserrat(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios,
                  color: Colors.grey[400],
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
