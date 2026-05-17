// ignore_for_file: library_private_types_in_public_api, deprecated_member_use, empty_catches, use_build_context_synchronously, unused_local_variable
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:fl_chart/fl_chart.dart';
import 'services/device_api_service.dart';
import 'services/api_service.dart';
import 'utils/flutter_state_ext.dart';
import 'widgets/fixed_measurement_actions.dart';
import 'widgets/bluetooth_status_banner.dart';
import 'services/bluetooth_connectivity_service.dart';

class MeasurementData {
  final DateTime timestamp;
  final double? tc;
  final double? hdl;
  final double? ldl;
  final double? tg;

  MeasurementData({
    required this.timestamp,
    this.tc,
    this.hdl,
    this.ldl,
    this.tg,
  });
}

class BloodLipidMonitorPage extends StatefulWidget {
  final String? patientId;

  const BloodLipidMonitorPage({super.key, this.patientId});

  @override
  _BloodLipidMonitorPageState createState() => _BloodLipidMonitorPageState();
}

class _BloodLipidMonitorPageState extends State<BloodLipidMonitorPage>
    with TickerProviderStateMixin {
  static const Color _primaryBlue = Color.fromARGB(218, 44, 51, 133);

  final BluetoothConnectivityService _bluetoothService = BluetoothConnectivityService();
  final List<ScanResult> _scanResults = [];
  final List<ScanResult> _lysunDevices = [];
  BluetoothDevice? _device;
  List<BluetoothService> _services = [];
  bool _isScanning = false;
  bool _isConnecting = false;

  // Animation controllers
  late AnimationController _pulseController;
  late AnimationController _slideController;

  // Stream subscriptions for proper disposal
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<bool>? _isScanningSubscription;
  StreamSubscription<List<int>>? _characteristicSubscription;

  // Disposal flag to prevent any operations after dispose
  bool _disposed = false;

  // Measurements - using String to handle "Low", "High", actual values
  String? totalCholesterol;
  String? hdlCholesterol;
  String? ldlCholesterol;
  String? triglycerides;

  // Buffer to accumulate partial data
  String _dataBuffer = '';

  // Save/Retry state
  bool _isSaving = false;
  bool _isSaved = false;

  // History data for graph
  final List<MeasurementData> _historyData = [];
  final List<MeasurementData> _apiHistoryData = []; // From API
  bool _isLoadingHistory = false;
  final ApiService _apiService = ApiService();

  // Target device name for auto-connect
  static const String TARGET_DEVICE_NAME = "LYSUN LPM-101";

  // Device confirmation state
  bool _hasConfirmedDeviceOn = false;

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

    // Load lipid history from API
    _loadLipidHistory();

    // Listen to scan results and filter for LYSUN devices
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (_disposed) return;

      setStateIfMounted(() {
        _scanResults.clear();
        _scanResults.addAll(results);

        // Filter for LYSUN devices only
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
    // Show confirmation dialog instead of auto-scanning
    if (mounted && !_hasConfirmedDeviceOn) {
      _showDeviceConfirmationDialog();
    }
  }

  void _showDeviceConfirmationDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.bluetooth, color: Color(0xFF2c3385), size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Connect Device',
                  style: GoogleFonts.montserrat(
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                    color: Color(0xFF2c3385),
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue.shade700, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Make sure your Lipid Profile Monitor is turned ON before proceeding.',
                        style: GoogleFonts.montserrat(
                          fontSize: 14,
                          color: Colors.blue.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'The app will start searching for your device after you confirm.',
                style: GoogleFonts.montserrat(
                  fontSize: 13,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  setStateIfMounted(() {
                    _hasConfirmedDeviceOn = true;
                  });
                  _autoStartScanning();
                },
                icon: Icon(Icons.power_settings_new, color: Colors.white),
                label: Text(
                  'I turned on my device',
                  style: GoogleFonts.montserrat(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Color(0xFF2c3385),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
  
  Future<void> _initBluetooth() async {
    // Check Bluetooth status using centralized service
    final bluetoothStatus = await _bluetoothService.checkBluetoothStatus();
    final permissionStatus = await _bluetoothService.checkPermissions();

    if (bluetoothStatus == BluetoothStatus.unsupported) {
      return;
    }

    if (permissionStatus != BluetoothPermissionStatus.granted) {
      // Show dialog to request permissions
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => BluetoothRequirementDialog(
          deviceType: 'Blood Lipid Monitor',
        ),
      );

      if (result != true) {
        return;
      }
    }

    if (bluetoothStatus != BluetoothStatus.on) {
      // Show dialog to enable Bluetooth
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => BluetoothRequirementDialog(
          deviceType: 'Blood Lipid Monitor',
        ),
      );

      if (result != true) {
        return;
      }
    }
  }
  
  void _autoStartScanning() {
    debugPrint('🔄 _autoStartScanning called for Lipid Monitor');
    debugPrint('  - mounted: $mounted');
    debugPrint('  - device connected: ${_device != null}');
    debugPrint('  - isScanning: $_isScanning');

    // Auto-start scanning after UI is ready
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted && _device == null && !_isScanning) {
        debugPrint('🔍 Auto-starting Lipid Monitor device scan...');
        _startScan();
      } else {
        debugPrint('⚠️ Auto-scan skipped:');
        if (!mounted) debugPrint('  - Widget not mounted');
        if (_device != null) debugPrint('  - Already connected');
        if (_isScanning) debugPrint('  - Already scanning');
      }
    });
  }
  
  void _autoConnectIfTargetFound(List<ScanResult> results) {
    if (_disposed || _device != null || _isConnecting) return;
    
    // Look for LYSUN LPM-101 device
    for (var result in results) {
      // Try multiple ways to get the device name (same as BP monitor)
      final deviceLocalName = result.device.localName;
      final advLocalName = result.advertisementData.localName;
      final platformName = result.device.platformName;
      final advName = result.advertisementData.advName;
      
      // Use whichever name is available (prioritize localName like BP monitor)
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
      
      debugPrint('🔍 Scan result - deviceLocalName: "$deviceLocalName", advLocalName: "$advLocalName", platformName: "$platformName", advName: "$advName"');
      
      // Case-insensitive comparison with trimmed strings
      final normalizedDeviceName = deviceName.trim().toUpperCase();
      
      // Check if device name matches - ONLY match LPM-101 (Lipid Profile Monitor)
      // Avoid matching other LYSUN devices like glucose meter
      final isTargetDevice = normalizedDeviceName == TARGET_DEVICE_NAME.toUpperCase() ||
          normalizedDeviceName.contains('LPM-101') ||
          normalizedDeviceName.contains('LPM 101') ||
          normalizedDeviceName == 'LPM101' ||
          // Only match LYSUN if it also contains LPM (lipid profile monitor)
          (normalizedDeviceName.contains('LYSUN') && normalizedDeviceName.contains('LPM'));
      
      if (isTargetDevice && deviceName.isNotEmpty) {
        debugPrint('🎯 Found target device: "$deviceName", auto-connecting...');
        
        // Stop scanning first
        FlutterBluePlus.stopScan();
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Found $deviceName, connecting automatically...'),
              backgroundColor: Colors.blue,
              duration: Duration(seconds: 2),
            ),
          );
        }
        
        // Small delay before auto-connecting
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _device == null && !_isConnecting) {
            _connectToDevice(result.device);
          }
        });
        
        break;
      }
    }
  }

  Future<void> _loadLipidHistory() async {
    debugPrint(
        '🔍 _loadLipidHistory called with patientId: ${widget.patientId}');

    if (widget.patientId == null) {
      debugPrint('⚠️ No patient ID provided, skipping lipid history load');
      return;
    }

    debugPrint(
        '🔍 Starting to load lipid history for patient: ${widget.patientId}');
    setStateIfMounted(() {
      _isLoadingHistory = true;
    });

    try {
      debugPrint('🔍 Calling API getPatientVitalHistory...');
      final response =
          await _apiService.getPatientVitalHistory(widget.patientId!);
      debugPrint('🔍 API call completed. Success: ${response.isSuccess}');

      if (response.isSuccess && response.data != null) {
        debugPrint('📊 API Response data: ${response.data}');
        final sessions = response.data!['sessions'] as List<dynamic>? ?? [];
        debugPrint('📊 Total sessions: ${sessions.length}');
        final List<MeasurementData> lipidReadings = [];

        // Extract lipid measurements from sessions
        for (final session in sessions) {
          final measurements = session['measurements'] as List<dynamic>? ?? [];
          debugPrint('📊 Session has ${measurements.length} measurements');

          for (final measurement in measurements) {
            final measurementType = measurement['measurement_type'];
            debugPrint('📊 Measurement type: $measurementType');

            if (measurementType == 'LIPID') {
              final lipidPanel =
                  measurement['lipid_panel'] as Map<String, dynamic>?;
              if (lipidPanel != null) {
                final measuredAt = measurement['measured_at'] as String?;

                // Extract lipid values (handle both int and double)
                final tcValue = lipidPanel['total_cholesterol'];
                final hdlValue = lipidPanel['hdl_cholesterol'];
                final ldlValue = lipidPanel['ldl_cholesterol'];
                final tgValue = lipidPanel['triglycerides'];

                // Convert to double (handle both int and double)
                final tc =
                    tcValue is double ? tcValue : (tcValue as num?)?.toDouble();
                final hdl = hdlValue is double
                    ? hdlValue
                    : (hdlValue as num?)?.toDouble();
                final ldl = ldlValue is double
                    ? ldlValue
                    : (ldlValue as num?)?.toDouble();
                final tg =
                    tgValue is double ? tgValue : (tgValue as num?)?.toDouble();

                debugPrint(
                    '📊 Lipid Reading: TC=$tc, HDL=$hdl, LDL=$ldl, TG=$tg, Date=$measuredAt');

                if (measuredAt != null &&
                    (tc != null || hdl != null || ldl != null || tg != null)) {
                  lipidReadings.add(
                    MeasurementData(
                      timestamp: DateTime.parse(measuredAt),
                      tc: tc,
                      hdl: hdl,
                      ldl: ldl,
                      tg: tg,
                    ),
                  );
                }
              }
            }
          }
        }

        // Sort by date (most recent first)
        lipidReadings.sort((a, b) => b.timestamp.compareTo(a.timestamp));

        setStateIfMounted(() {
          _apiHistoryData.clear();
          _apiHistoryData.addAll(lipidReadings);
          _isLoadingHistory = false;
        });

        debugPrint(
            '✅ Loaded ${lipidReadings.length} lipid readings from history');
        debugPrint(
            '📊 History readings: ${lipidReadings.map((r) => 'TC=${r.tc}, HDL=${r.hdl}, LDL=${r.ldl}, TG=${r.tg} @ ${r.timestamp}').join(', ')}');
      } else {
        debugPrint('❌ Failed to load lipid history: ${response.error}');
        setStateIfMounted(() {
          _isLoadingHistory = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Error loading lipid history: $e');
      setStateIfMounted(() {
        _isLoadingHistory = false;
      });
    }
  }

  // Helper method to identify LYSUN Lipid Profile Monitor devices
  // Only matches LPM-101 (Lipid Profile Monitor), not other LYSUN devices like glucose meter
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

    // Check for LPM-101 specifically (Lipid Profile Monitor)
    // Avoid matching other LYSUN devices like glucose meter
    return deviceName == TARGET_DEVICE_NAME.toLowerCase() ||
        deviceName.contains('lpm-101') ||
        deviceName.contains('lpm 101') ||
        deviceName == 'lpm101' ||
        deviceName.startsWith('lpm') ||
        // Only match LYSUN if it also contains LPM
        (deviceName.contains('lysun') && deviceName.contains('lpm')) ||
        // You can also check for specific service UUIDs if known
        _hasLysunServiceUuids(result);
  }

  bool _hasLysunServiceUuids(ScanResult result) {
    // Check for known LYSUN service UUIDs in advertisement data
    final advertisementData = result.advertisementData;
    final serviceUuids = advertisementData.serviceUuids;

    // Add known LYSUN service UUIDs here
    const lysunServiceUuids = [
      'd44bc439-abfd-45a2-b575-925416129600',
      'd44bc439-abfd-45a2-b575-925416129601',
      // Add more known LYSUN service UUIDs
    ];

    return serviceUuids.any(
      (uuid) => lysunServiceUuids.contains(uuid.toString().toLowerCase()),
    );
  }

  // Calculate TC/HDL ratio
  String? _calculateTcHdlRatio() {
    if (totalCholesterol == null || hdlCholesterol == null) {
      return null;
    }

    // Handle "Low" and "High" values
    if (totalCholesterol == "Low" ||
        totalCholesterol == "High" ||
        hdlCholesterol == "Low" ||
        hdlCholesterol == "High") {
      return "N/A";
    }

    try {
      final tc = double.parse(totalCholesterol!);
      final hdl = double.parse(hdlCholesterol!);

      if (hdl == 0) return "N/A";

      final ratio = tc / hdl;
      return ratio.toStringAsFixed(2);
    } catch (e) {
      return "N/A";
    }
  }

  // Get measurement status (Good, Low, High)
  String _getMeasurementStatus(String? value, String type) {
    if (value == null || value == "N/A" || value == "--") return "No Data";
    if (value == "Low" || value == "High") return value;

    try {
      final numValue = double.parse(value);

      switch (type) {
        case 'TC':
          if (numValue < 200) return "Good";
          if (numValue < 240) return "Borderline";
          return "High";
        case 'HDL':
          if (numValue >= 60) return "Good";
          if (numValue >= 40) return "Borderline";
          return "Low";
        case 'LDL':
          if (numValue < 100) return "Good";
          if (numValue < 130) return "Borderline";
          return "High";
        case 'TG':
          if (numValue < 150) return "Good";
          if (numValue < 200) return "Borderline";
          return "High";
        case 'RATIO':
          if (numValue < 5.0) return "Good";
          return "High";
        default:
          return "Unknown";
      }
    } catch (e) {
      return "Unknown";
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case "Good":
        return Colors.green;
      case "Borderline":
        return Colors.orange;
      case "High":
      case "Low":
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  // Add measurement to history
  void _addToHistory() {
    final now = DateTime.now();

    double? tc, hdl, ldl, tg;

    try {
      if (totalCholesterol != null &&
          totalCholesterol != "Low" &&
          totalCholesterol != "High" &&
          totalCholesterol != "N/A") {
        tc = double.parse(totalCholesterol!);
      }
    } catch (e) {}

    try {
      if (hdlCholesterol != null &&
          hdlCholesterol != "Low" &&
          hdlCholesterol != "High" &&
          hdlCholesterol != "N/A") {
        hdl = double.parse(hdlCholesterol!);
      }
    } catch (e) {}

    try {
      if (ldlCholesterol != null &&
          ldlCholesterol != "Low" &&
          ldlCholesterol != "High" &&
          ldlCholesterol != "N/A") {
        ldl = double.parse(ldlCholesterol!);
      }
    } catch (e) {}

    try {
      if (triglycerides != null &&
          triglycerides != "Low" &&
          triglycerides != "High" &&
          triglycerides != "N/A") {
        tg = double.parse(triglycerides!);
      }
    } catch (e) {}

    if (tc != null || hdl != null || ldl != null || tg != null) {
      if (!_disposed) {
        // Check if this reading already exists (prevent duplicates)
        final isDuplicate = _historyData.any((existing) =>
            existing.tc == tc &&
            existing.hdl == hdl &&
            existing.ldl == ldl &&
            existing.tg == tg &&
            now.difference(existing.timestamp).abs().inSeconds < 5);

        if (!isDuplicate) {
          setStateIfMounted(() {
            _historyData.add(
              MeasurementData(
                  timestamp: now, tc: tc, hdl: hdl, ldl: ldl, tg: tg),
            );

            // Keep only last 10 measurements
            if (_historyData.length > 10) {
              _historyData.removeAt(0);
            }
          });
          debugPrint(
              '✅ Lipid reading added: TC=$tc, HDL=$hdl, LDL=$ldl, TG=$tg');
        } else {
          debugPrint(
              '⚠️ Duplicate lipid reading detected, skipping: TC=$tc, HDL=$hdl, LDL=$ldl, TG=$tg');
        }
      }
    }
  }

  @override
  void dispose() {
    // Set disposal flag first
    _disposed = true;

    // Use FlutterBluePlus-specific cleanup methods for proper stream termination
    try {
      if (_scanResultsSubscription != null) {
        FlutterBluePlus.cancelWhenScanComplete(_scanResultsSubscription!);
        _scanResultsSubscription = null;
      }
    } catch (e) {
      debugPrint('Error canceling scan results subscription: $e');
    }

    try {
      if (_isScanningSubscription != null) {
        FlutterBluePlus.cancelWhenScanComplete(_isScanningSubscription!);
        _isScanningSubscription = null;
      }
    } catch (e) {
      debugPrint('Error canceling scanning subscription: $e');
    }

    try {
      if (_characteristicSubscription != null) {
        // For device-specific subscriptions, use device.cancelWhenDisconnected if device is available
        if (_device != null) {
          _device!.cancelWhenDisconnected(_characteristicSubscription!);
        } else {
          _characteristicSubscription?.cancel();
        }
        _characteristicSubscription = null;
      }
    } catch (e) {
      debugPrint('Error canceling characteristic subscription: $e');
    }

    _pulseController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    // Check Bluetooth status first
    if (!_bluetoothService.canScan()) {
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => BluetoothRequirementDialog(
          deviceType: 'Blood Lipid Monitor',
        ),
      );

      if (result != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bluetooth not ready')),
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

      // Start scanning
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

      debugPrint("Scan started successfully");
    } catch (e) {
      debugPrint("Scan error: $e");
      if (!_disposed) {
        setStateIfMounted(() {
          _isScanning = false;
        });
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

    for (var service in _services) {
      debugPrint('Service: ${service.uuid}');

      for (var characteristic in service.characteristics) {
        debugPrint('  Characteristic: ${characteristic.uuid}');
        debugPrint('  Properties: ${characteristic.properties}');

        try {
          // Skip device information characteristics
          if (_isDeviceInfoCharacteristic(characteristic.uuid.toString())) {
            debugPrint('  -> Skipping device info characteristic');
            continue;
          }

          // Find the notification characteristic for measurements
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

          // Find write characteristics for sending commands
          if (characteristic.uuid.toString() ==
              'd44bc439-abfd-45a2-b575-925416129600') {
            writeChar = characteristic;
            debugPrint('  -> Primary write characteristic found');
          }

          if (characteristic.uuid.toString() == 'ff01') {
            writeChar2 = characteristic;
            debugPrint('  -> Secondary write characteristic found');
          }
        } catch (e) {
          debugPrint('  -> Setup failed for characteristic: $e');
        }
      }
    }

    // Try to trigger measurements
    await _requestMeasurements(writeChar, writeChar2);
  }

  bool _isDeviceInfoCharacteristic(String uuid) {
    // These are standard BLE device information characteristics
    final deviceInfoUuids = [
      '2a00',
      '2a01',
      '2a04',
      '2a05',
      '2a23',
      '2a24',
      '2a25',
      '2a26',
      '2a27',
      '2a28',
      '2a29',
      '2a2a',
      '2a50',
      'fff3',
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

    // Simple commands to trigger measurements
    final commands = [
      [0x01],
      [0x02],
      [0x03],
      [0xAA, 0x55],
      [0xFF, 0x01],
    ];

    debugPrint('Attempting to trigger measurements...');

    for (int i = 0; i < commands.length; i++) {
      final command = commands[i];
      debugPrint('Trying command ${i + 1}/${commands.length}: $command');

      try {
        if (writeChar != null) {
          if (writeChar.properties.writeWithoutResponse) {
            await writeChar.write(command, withoutResponse: true);
          } else if (writeChar.properties.write) {
            await writeChar.write(command);
          }
          await Future.delayed(const Duration(milliseconds: 500));
        }

        if (writeChar2 != null) {
          if (writeChar2.properties.writeWithoutResponse) {
            await writeChar2.write(command, withoutResponse: true);
          } else if (writeChar2.properties.write) {
            await writeChar2.write(command);
          }
          await Future.delayed(const Duration(milliseconds: 500));
        }
      } catch (e) {
        debugPrint('  -> Command failed: $e');
      }
    }
  }

  void _parseTextMeasurement(List<int> val) {
    if (val.isEmpty) return;

    try {
      // Convert bytes to string
      String text = String.fromCharCodes(val);
      debugPrint('Received text: "$text"');

      // Add to buffer for handling fragmented messages
      _dataBuffer += text;

      // Process complete lines (ending with \r\n or \n)
      List<String> lines = _dataBuffer.split(RegExp(r'[\r\n]+'));

      // Keep the last incomplete line in buffer
      if (!_dataBuffer.endsWith('\n') && !_dataBuffer.endsWith('\r\n')) {
        _dataBuffer = lines.last;
        lines = lines.sublist(0, lines.length - 1);
      } else {
        _dataBuffer = '';
      }

      // Process each complete line
      for (String line in lines) {
        line = line.trim();
        if (line.isEmpty) continue;

        debugPrint('Processing line: "$line"');
        _parseTextLine(line);
      }
    } catch (e) {
      debugPrint('Text parsing error: $e');
    }
  }

  void _parseTextLine(String line) {
    // Parse different measurement formats
    if (!_disposed) {
      setStateIfMounted(() {
        if (line.startsWith('TC ') || line.startsWith('TC:')) {
          // Total Cholesterol
          totalCholesterol = _extractValue(line);
        } else if (line.startsWith('TG ') || line.startsWith('TG:')) {
          // Triglycerides
          triglycerides = _extractValue(line);
        } else if (line.startsWith('HDL') || line.startsWith('HDL:')) {
          // HDL Cholesterol
          hdlCholesterol = _extractValue(line);
        } else if (line.startsWith('LDL') || line.startsWith('LDL:')) {
          // LDL Cholesterol
          ldlCholesterol = _extractValue(line);
        }
      });
    }

    debugPrint('Updated measurements:');
    debugPrint('  TC: $totalCholesterol');
    debugPrint('  TG: $triglycerides');
    debugPrint('  HDL: $hdlCholesterol');
    debugPrint('  LDL: $ldlCholesterol');
    debugPrint('  TC/HDL Ratio: ${_calculateTcHdlRatio()}');

    // Only add to history when we have all 4 values (complete reading)
    if (totalCholesterol != null &&
        triglycerides != null &&
        hdlCholesterol != null &&
        ldlCholesterol != null &&
        totalCholesterol != "N/A" &&
        triglycerides != "N/A" &&
        hdlCholesterol != "N/A" &&
        ldlCholesterol != "N/A") {
      debugPrint('✅ Complete lipid reading received, adding to history');
      _addToHistory();
    } else {
      debugPrint('⏳ Incomplete reading, waiting for all values...');
    }
  }

  String _extractValue(String line) {
    // Remove the parameter name and extract the value
    String value = line;

    // Remove common prefixes
    value = value.replaceAll(RegExp(r'^(TC|TG|HDL|LDL|UA|URIC)\s*[:\s]+'), '');

    // Remove common suffixes like "mg/dL", "m", etc.
    value = value.replaceAll(RegExp(r'\s*(mg/dL|mg|m)\s*$'), '');

    // Trim whitespace
    value = value.trim();

    // If it's empty, return the original line
    if (value.isEmpty) return line;

    return value;
  }

  Future<void> _triggerMeasurement() async {
    if (_device == null || _services.isEmpty) {
      debugPrint('Device not connected or services not discovered');
      return;
    }

    BluetoothCharacteristic? writeChar;
    BluetoothCharacteristic? writeChar2;

    // Find write characteristics
    for (var service in _services) {
      for (var characteristic in service.characteristics) {
        if (characteristic.uuid.toString() ==
            'd44bc439-abfd-45a2-b575-925416129600') {
          writeChar = characteristic;
        }
        if (characteristic.uuid.toString() == 'ff01') {
          writeChar2 = characteristic;
        }
      }
    }

    await _requestMeasurements(writeChar, writeChar2);
  }

  Future<void> _disconnect() async {
    if (_device != null) {
      try {
        await _device!.disconnect();
        debugPrint("Disconnected from ${_device!.name}");

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Disconnected from ${_device!.name}"),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } catch (e) {
        debugPrint("Disconnect error: $e");
      }

      if (!_disposed) {
        setStateIfMounted(() {
          _device = null;
          _services.clear();
          totalCholesterol = null;
          hdlCholesterol = null;
          ldlCholesterol = null;
          triglycerides = null;
          _dataBuffer = '';
        });
      }

      _slideController.reverse();
    }
  }

  // Helper method to build chart legend
  Widget _buildChartLegend() {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      runSpacing: 8,
      children: [
        _buildLegendItem('TC', Colors.red),
        _buildLegendItem('HDL', Color(0xFF2c3385)),
        _buildLegendItem('LDL', Colors.orange),
        _buildLegendItem('TG', Colors.purple),
      ],
    );
  }

  Widget _buildLegendItem(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: GoogleFonts.montserrat(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade700,
          ),
        ),
      ],
    );
  }

  // Helper method to get combined history data (live + API)
  List<MeasurementData> _getCombinedHistoryData() {
    // Debug: Chart Data - Live readings: ${_historyData.length}, API readings: ${_apiHistoryData.length}

    // Combine live readings and API history readings
    final allReadings = [..._historyData, ..._apiHistoryData];
    // Debug: Combined readings count: ${allReadings.length}

    // Remove duplicates based on timestamp (keep the first occurrence)
    final seen = <String>{};
    final uniqueReadings = allReadings.where((reading) {
      final key = reading.timestamp.toIso8601String();
      if (seen.contains(key)) {
        return false;
      }
      seen.add(key);
      return true;
    }).toList();
    // Debug: Unique readings: ${uniqueReadings.length}

    // Sort by date (oldest first for chart display)
    uniqueReadings.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Debug: Chart readings: ${uniqueReadings.map((r) => 'TC=${r.tc}, HDL=${r.hdl} @ ${DateFormat('dd/MM').format(r.timestamp)}').join(', ')}

    return uniqueReadings;
  }

  // Helper method to calculate maximum Y value for better scaling
  double _getMaxYValue() {
    final combinedData = _getCombinedHistoryData();
    if (combinedData.isEmpty) return 300;

    double maxValue = 0;
    for (final data in combinedData) {
      if (data.tc != null && data.tc! > maxValue) maxValue = data.tc!;
      if (data.hdl != null && data.hdl! > maxValue) maxValue = data.hdl!;
      if (data.ldl != null && data.ldl! > maxValue) maxValue = data.ldl!;
      if (data.tg != null && data.tg! > maxValue) maxValue = data.tg!;
    }

    // Add 20% padding to the maximum value for better visualization
    return (maxValue * 1.2).clamp(200, 400);
  }

  // Helper method to generate line chart bars with proper data filtering
  List<LineChartBarData> _getLineChartBars() {
    final List<LineChartBarData> bars = [];
    final combinedData = _getCombinedHistoryData();

    // TC Line (Red) - Only include points with TC data
    final tcSpots = <FlSpot>[];
    for (int i = 0; i < combinedData.length; i++) {
      if (combinedData[i].tc != null) {
        tcSpots.add(FlSpot(i.toDouble(), combinedData[i].tc!));
      }
    }
    if (tcSpots.isNotEmpty) {
      bars.add(
        LineChartBarData(
          spots: tcSpots,
          isCurved:
              false, // Changed to false for more accurate point representation
          color: Colors.red,
          barWidth: 3,
          isStrokeCapRound: true,
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, barData, index) {
              return FlDotCirclePainter(
                radius: 5,
                color: Colors.red,
                strokeWidth: 2,
                strokeColor: Colors.white,
              );
            },
          ),
          belowBarData: BarAreaData(show: false),
        ),
      );
    }

    // HDL Line (Blue)
    final hdlSpots = <FlSpot>[];
    for (int i = 0; i < combinedData.length; i++) {
      if (combinedData[i].hdl != null) {
        hdlSpots.add(FlSpot(i.toDouble(), combinedData[i].hdl!));
      }
    }
    if (hdlSpots.isNotEmpty) {
      bars.add(
        LineChartBarData(
          spots: hdlSpots,
          isCurved: false,
          color: Color(0xFF2c3385),
          barWidth: 3,
          isStrokeCapRound: true,
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, barData, index) {
              return FlDotCirclePainter(
                radius: 5,
                color: Color(0xFF2c3385),
                strokeWidth: 2,
                strokeColor: Colors.white,
              );
            },
          ),
          belowBarData: BarAreaData(show: false),
        ),
      );
    }

    // LDL Line (Orange)
    final ldlSpots = <FlSpot>[];
    for (int i = 0; i < combinedData.length; i++) {
      if (combinedData[i].ldl != null) {
        ldlSpots.add(FlSpot(i.toDouble(), combinedData[i].ldl!));
      }
    }
    if (ldlSpots.isNotEmpty) {
      bars.add(
        LineChartBarData(
          spots: ldlSpots,
          isCurved: false,
          color: Colors.orange,
          barWidth: 3,
          isStrokeCapRound: true,
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, barData, index) {
              return FlDotCirclePainter(
                radius: 5,
                color: Colors.orange,
                strokeWidth: 2,
                strokeColor: Colors.white,
              );
            },
          ),
          belowBarData: BarAreaData(show: false),
        ),
      );
    }

    // TG Line (Purple)
    final tgSpots = <FlSpot>[];
    for (int i = 0; i < combinedData.length; i++) {
      if (combinedData[i].tg != null) {
        tgSpots.add(FlSpot(i.toDouble(), combinedData[i].tg!));
      }
    }
    if (tgSpots.isNotEmpty) {
      bars.add(
        LineChartBarData(
          spots: tgSpots,
          isCurved: false,
          color: Colors.purple,
          barWidth: 3,
          isStrokeCapRound: true,
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, barData, index) {
              return FlDotCirclePainter(
                radius: 5,
                color: Colors.purple,
                strokeWidth: 2,
                strokeColor: Colors.white,
              );
            },
          ),
          belowBarData: BarAreaData(show: false),
        ),
      );
    }

    return bars;
  }

  @override
  Widget build(BuildContext context) {
    return BluetoothStatusBanner(
      child: WillPopScope(
        onWillPop: () async {
          // Disconnect from device when navigating back
          if (_device != null) {
            await _device!.disconnect();
          }
          return true;
        },
        child: Scaffold(
          backgroundColor: Colors.white,
          body: SafeArea(
          child: Column(
            children: [
              // Scrollable content
              Expanded(
                child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(),

                    // Connection Status
                    if (_device != null) ...[
                      const SizedBox(height: 8), // Reduced space
                      _buildConnectionStatus(),
                    ],

                    // Measurements Section
                    if (_device != null) ...[
                      const SizedBox(height: 24),
                      _buildSectionTitle(
                        icon: FontAwesomeIcons.chartLine,
                        title: 'Latest Measurements',
                      ),
                      const SizedBox(height: 16),
                      _buildMeasurementsGrid(),
                      // Removed action buttons here - they're now at bottom
                      const SizedBox(height: 24),
                      _buildSectionTitle(
                        icon: FontAwesomeIcons.chartArea,
                        title: 'History',
                      ),
                      const SizedBox(height: 16),

                      // Show loading indicator when loading history
                      if (_isLoadingHistory) ...[
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24.0),
                            child: Column(
                              children: [
                                CircularProgressIndicator(
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      _primaryBlue),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Loading lipid history...',
                                  style: GoogleFonts.montserrat(
                                    fontSize: 14,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ] else ...[
                        _buildHistoryChart(),
                      ],
                      const SizedBox(height: 24),
                    ],

                    // Scanning Section
                    if (_device == null) ...[
                      _buildScanningSection(),
                      const SizedBox(height: 16),
                      if (_lysunDevices.isNotEmpty)
                        _buildSectionTitle(
                          icon: FontAwesomeIcons.bluetooth,
                          title: 'Blood Lipid Analysis Meters Found',
                        ),
                      ..._lysunDevices
                          .map((result) => _buildDeviceCard(result)),

                      // Show message if no LYSUN devices found but other devices are present
                      if (_lysunDevices.isEmpty &&
                          _scanResults.isNotEmpty &&
                          !_isScanning)
                        _buildNoLysunDevicesMessage(),
                    ],
                  ],
                ),
              ),
            ),
            // Fixed bottom save buttons (only show when there are measurements to save)
            if (_device != null && _hasAnyMeasurements())
              FixedMeasurementActions(
                onSave: _saveLipidMeasurements,
                onRetake: _takeAnotherLipidReading,
                isSaving: _isSaving,
                isSaved: _isSaved,
                saveButtonText: 'Save & Continue',
                retakeButtonText: 'Take Another Reading',
                savingButtonText: 'Saving...',
              ),
          ],
        ),
      ),
        ),
      ),
    );
  }

  Widget _buildHistoryChart() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 2,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          padding: const EdgeInsets.all(20),
          height: 350, // Increased height for better visibility
          child: _getCombinedHistoryData().isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FaIcon(
                        FontAwesomeIcons.chartLine,
                        color: Colors.grey.shade400,
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No measurement history yet',
                        style: GoogleFonts.montserrat(
                          fontSize: 16,
                          color: Colors.grey.shade600,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Take measurements to see your health trends',
                        style: GoogleFonts.montserrat(
                          fontSize: 14,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Legend
                    _buildChartLegend(),
                    const SizedBox(height: 16),
                    // Chart
                    Expanded(
                      child: LineChart(
                        LineChartData(
                          backgroundColor: Colors.white,
                          gridData: FlGridData(
                            show: true,
                            drawVerticalLine: true,
                            horizontalInterval: 50,
                            verticalInterval:
                                _getCombinedHistoryData().length > 1 ? 1 : 0.5,
                            getDrawingHorizontalLine: (value) {
                              return FlLine(
                                color: Colors.grey.shade200,
                                strokeWidth: 1,
                              );
                            },
                            getDrawingVerticalLine: (value) {
                              return FlLine(
                                color: Colors.grey.shade200,
                                strokeWidth: 1,
                              );
                            },
                          ),
                          titlesData: FlTitlesData(
                            show: true,
                            rightTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            topTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 35,
                                interval: 1,
                                getTitlesWidget:
                                    (double value, TitleMeta meta) {
                                  final index = value.toInt();
                                  final combinedData =
                                      _getCombinedHistoryData();
                                  if (index >= 0 &&
                                      index < combinedData.length) {
                                    final data = combinedData[index];
                                    final hour = data.timestamp.hour;
                                    final minute = data.timestamp.minute
                                        .toString()
                                        .padLeft(2, '0');
                                    final day = data.timestamp.day;
                                    final month = data.timestamp.month;

                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        top: 8.0,
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '$hour:$minute',
                                            style: GoogleFonts.montserrat(
                                              color: Colors.grey.shade600,
                                              fontWeight: FontWeight.w500,
                                              fontSize: 10,
                                            ),
                                          ),
                                          Text(
                                            '$day/$month',
                                            style: GoogleFonts.montserrat(
                                              color: Colors.grey.shade500,
                                              fontWeight: FontWeight.w400,
                                              fontSize: 8,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                  return const Text('');
                                },
                              ),
                            ),
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                interval: 50,
                                getTitlesWidget:
                                    (double value, TitleMeta meta) {
                                  return Text(
                                    '${value.toInt()}',
                                    style: GoogleFonts.montserrat(
                                      color: Colors.grey.shade600,
                                      fontWeight: FontWeight.w500,
                                      fontSize: 11,
                                    ),
                                  );
                                },
                                reservedSize: 45,
                              ),
                            ),
                          ),
                          borderData: FlBorderData(
                            show: true,
                            border: Border.all(
                              color: Colors.grey.shade300,
                              width: 1,
                            ),
                          ),
                          minX: 0,
                          maxX:
                              (_getCombinedHistoryData().length - 1).toDouble(),
                          minY: 0,
                          maxY: _getMaxYValue(),
                          lineBarsData: _getLineChartBars(),
                          // Add touch interaction
                          lineTouchData: LineTouchData(
                            enabled: true,
                            touchTooltipData: LineTouchTooltipData(
                              getTooltipColor: (touchedSpot) =>
                                  Colors.blueGrey.shade800,
                              getTooltipItems:
                                  (List<LineBarSpot> touchedBarSpots) {
                                return touchedBarSpots.map((barSpot) {
                                  final index = barSpot.x.toInt();
                                  final combinedData =
                                      _getCombinedHistoryData();
                                  if (index >= 0 &&
                                      index < combinedData.length) {
                                    final data = combinedData[index];
                                    final timestamp =
                                        '${data.timestamp.hour}:${data.timestamp.minute.toString().padLeft(2, '0')}';

                                    String label = '';
                                    switch (barSpot.barIndex) {
                                      case 0:
                                        label =
                                            'TC: ${barSpot.y.toInt()} mg/dL';
                                        break;
                                      case 1:
                                        label =
                                            'HDL: ${barSpot.y.toInt()} mg/dL';
                                        break;
                                      case 2:
                                        label =
                                            'LDL: ${barSpot.y.toInt()} mg/dL';
                                        break;
                                      case 3:
                                        label =
                                            'TG: ${barSpot.y.toInt()} mg/dL';
                                        break;
                                    }

                                    return LineTooltipItem(
                                      '$label\n$timestamp',
                                      GoogleFonts.montserrat(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    );
                                  }
                                  return null;
                                }).toList();
                              },
                            ),
                            touchCallback: (
                              FlTouchEvent event,
                              LineTouchResponse? touchResponse,
                            ) {
                              // Handle touch events if needed
                            },
                            handleBuiltInTouches: true,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildNoLysunDevicesMessage() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              colors: [Colors.orange.shade50, Colors.orange.shade100],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            children: [
              FaIcon(
                FontAwesomeIcons.triangleExclamation,
                color: Colors.orange,
                size: 32,
              ),
              const SizedBox(height: 12),
              Text(
                'No Blood Lipid Analysis Meters Found',
                style: GoogleFonts.montserrat(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.orange.shade800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Found ${_scanResults.length} other Bluetooth devices, but no Blood Lipid Analysis Meters. Please ensure your device is powered on and in pairing mode.',
                style: GoogleFonts.montserrat(
                  fontSize: 14,
                  color: Colors.orange.shade700,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: Container(
          height: 90,
          decoration: BoxDecoration(
            color: const Color(0xFF2c3385).withValues(alpha: 0.9),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // Back button
              IconButton(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                icon: const Icon(
                  Icons.arrow_back,
                  color: Colors.white,
                  size: 24,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 8),
              // Title content
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Lipid Profile Monitor',
                      style: GoogleFonts.raleway(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        shadows: [],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _device != null
                          ? 'Connected & monitoring your health'
                          : 'Scan & connect to Lipid Profile devices',
                      style: GoogleFonts.raleway(
                        color: Colors.white,
                        fontSize: 16,
                        shadows: [],
                      ),
                    ),
                  ],
                ),
              ),
              // Bluetooth icon when scanning
              if (_isScanning)
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: 1.0 + (_pulseController.value * 0.3),
                      child: FaIcon(
                        FontAwesomeIcons.bluetooth,
                        color: Colors.white,
                        size: 30,
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionStatus() {
    return SlideTransition(
      position:
          Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero).animate(
        CurvedAnimation(parent: _slideController, curve: Curves.easeOut),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Card(
          elevation: 3,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.green,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const FaIcon(
                    FontAwesomeIcons.bluetooth,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connected Device',
                        style: GoogleFonts.montserrat(
                          fontSize: 12,
                          color: Colors.grey.shade700,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _device!.name.isNotEmpty
                            ? _device!.name
                            : _device!.id.id,
                        style: GoogleFonts.montserrat(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _triggerMeasurement,
                  icon: const FaIcon(FontAwesomeIcons.play, size: 12),
                  label: Text(
                    'Measure',
                    style: GoogleFonts.montserrat(fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _disconnect,
                  icon: const FaIcon(FontAwesomeIcons.powerOff, size: 12),
                  label: Text(
                    'Disconnect',
                    style: GoogleFonts.montserrat(fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle({required IconData icon, required String title}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 36, 8),
      child: Row(
        children: [
          FaIcon(icon, color: _primaryBlue, size: 25),
          const SizedBox(width: 12),
          Text(
            title,
            style: GoogleFonts.montserrat(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMeasurementsGrid() {
    final measurements = [
      {
        'name': 'Total Cholesterol',
        'shortName': 'TC',
        'value': totalCholesterol,
        'icon': FontAwesomeIcons.heart,
        'color': Colors.red,
        'unit': 'mg/dL',
        'type': 'TC',
      },
      {
        'name': 'HDL',
        'shortName': 'HDL',
        'value': hdlCholesterol,
        'icon': FontAwesomeIcons.heartPulse,
        'color': Color(0xFF2c3385),
        'unit': 'mg/dL',
        'type': 'HDL',
      },
      {
        'name': 'LDL',
        'shortName': 'LDL',
        'value': ldlCholesterol,
        'icon': FontAwesomeIcons.heartCircleCheck,
        'color': Colors.orange,
        'unit': 'mg/dL',
        'type': 'LDL',
      },
      {
        'name': 'Triglycerides',
        'shortName': 'TG',
        'value': triglycerides,
        'icon': FontAwesomeIcons.droplet,
        'color': Colors.purple,
        'unit': 'mg/dL',
        'type': 'TG',
      },
      {
        'name': 'TC/HDL Ratio',
        'shortName': 'RATIO',
        'value': _calculateTcHdlRatio(),
        'icon': FontAwesomeIcons.calculator,
        'color': Colors.teal,
        'unit': 'Ratio',
        'type': 'RATIO',
      },
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 1.0, // Reduced height
        ),
        itemCount: measurements.length,
        itemBuilder: (context, index) {
          final measurement = measurements[index];
          return _buildCompactMeasurementCard(
            name: measurement['name'] as String,
            shortName: measurement['shortName'] as String,
            value: measurement['value'] as String?,
            icon: measurement['icon'] as IconData,
            color: measurement['color'] as Color,
            unit: measurement['unit'] as String,
            type: measurement['type'] as String,
          );
        },
      ),
    );
  }

  Widget _buildCompactMeasurementCard({
    required String name,
    required String shortName,
    required String? value,
    required IconData icon,
    required Color color,
    required String unit,
    required String type,
  }) {
    final hasValue = value != null;
    final status = _getMeasurementStatus(value, type);
    final statusColor = _getStatusColor(status);

    return Card(
      elevation: 2,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Icon
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: hasValue ? color : Colors.grey.shade400,
                borderRadius: BorderRadius.circular(8),
              ),
              child: FaIcon(icon, color: Colors.white, size: 18),
            ),
            const SizedBox(height: 12),

            // Parameter name
            Text(
              name,
              style: GoogleFonts.montserrat(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
                height: 1.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 20),

            // Value - Big font
            Text(
              value ?? "--",
              style: GoogleFonts.montserrat(
                fontWeight: FontWeight.w500,
                fontSize: hasValue ? 42 : 28,
                color: hasValue ? Colors.black87 : Colors.grey.shade400,
              ),
              textAlign: TextAlign.center,
            ),

            // Unit
            if (hasValue && unit.isNotEmpty)
              Text(
                unit,
                style: GoogleFonts.montserrat(
                  fontSize: 14,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),

            const SizedBox(height: 35),

            // Status
            if (hasValue)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: statusColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  status,
                  style: GoogleFonts.montserrat(
                    fontSize: 12,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanningSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 3,
        color: Colors.white, // Changed to white
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _isScanning
                        ? (1.0 + (_pulseController.value * 0.2))
                        : 1.0,
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color:
                            _isScanning ? _primaryBlue : Colors.grey.shade200,
                        shape: BoxShape.circle,
                      ),
                      child: FaIcon(
                        FontAwesomeIcons.bluetooth,
                        size: 40,
                        color:
                            _isScanning ? Colors.white : Colors.grey.shade500,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              Text(
                _isScanning
                    ? 'Scanning for Blood Lipid Analysis Meters...'
                    : 'Ready to scan',
                style: GoogleFonts.montserrat(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _isScanning
                    ? 'Looking for Blood Lipid Analysis Meters nearby'
                    : 'Press the button below to start scanning for Blood Lipid Analysis Meters',
                style: GoogleFonts.montserrat(
                  fontSize: 14,
                  color: Colors.grey.shade600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _isScanning ? _stopScan : _startScan,
                  icon: FaIcon(
                    _isScanning
                        ? FontAwesomeIcons.stop
                        : FontAwesomeIcons.magnifyingGlass,
                    size: 16,
                  ),
                  label: Text(
                    _isScanning
                        ? 'Stop Scanning'
                        : 'Scan for Blood Lipid Analysis Meters',
                    style: GoogleFonts.montserrat(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isScanning ? Colors.red : _primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceCard(ScanResult result) {
    final deviceName = result.device.name.isNotEmpty
        ? result.device.name
        : result.device.id.id;
    final signalStrength = result.rssi;
    final isStrongSignal = signalStrength > -70;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Card(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isStrongSignal ? _primaryBlue : Colors.orange,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: FaIcon(
                  FontAwesomeIcons.bluetooth,
                  size: 20,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      deviceName,
                      style: GoogleFonts.montserrat(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        FaIcon(
                          FontAwesomeIcons.signal,
                          size: 12,
                          color: isStrongSignal ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'RSSI: $signalStrength dBm',
                          style: GoogleFonts.montserrat(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color:
                                isStrongSignal ? Colors.green : Colors.orange,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            isStrongSignal ? 'Strong' : 'Weak',
                            style: GoogleFonts.montserrat(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _isConnecting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : ElevatedButton.icon(
                      onPressed: () => _connectToDevice(result.device),
                      icon: const FaIcon(FontAwesomeIcons.plug, size: 12),
                      label: Text(
                        'Connect',
                        style: GoogleFonts.montserrat(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primaryBlue,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: const Size(100, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  bool _hasAnyMeasurements() {
    return totalCholesterol != null ||
        hdlCholesterol != null ||
        ldlCholesterol != null ||
        triglycerides != null;
  }

  // Widget _buildLipidActionButtons() {
  //   if (_isSaved) {
  //     return Padding(
  //       padding: const EdgeInsets.symmetric(horizontal: 16),
  //       child: Card(
  //         color: Colors.green,
  //         elevation: 4,
  //         shape:
  //             RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  //         child: Padding(
  //           padding: const EdgeInsets.all(16),
  //           child: Row(
  //             mainAxisAlignment: MainAxisAlignment.center,
  //             children: const [
  //               Icon(Icons.check_circle, color: Colors.white, size: 24),
  //               SizedBox(width: 8),
  //               Text(
  //                 'Lipid Profile Saved!',
  //                 style: TextStyle(
  //                   color: Colors.white,
  //                   fontSize: 18,
  //                   fontWeight: FontWeight.bold,
  //                 ),
  //               ),
  //             ],
  //           ),
  //         ),
  //       ),
  //     );
  //   }

  //   return Padding(
  //     padding: const EdgeInsets.symmetric(horizontal: 16),
  //     child: Card(
  //       color: Colors.white,
  //       elevation: 4,
  //       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  //       child: Padding(
  //         padding: const EdgeInsets.all(16),
  //         child: Column(
  //           children: [
  //             Row(
  //               children: [
  //                 Icon(Icons.save, color: _primaryBlue, size: 24),
  //                 const SizedBox(width: 8),
  //                 Text(
  //                   'Save Lipid Profile',
  //                   style: GoogleFonts.montserrat(
  //                     fontSize: 20,
  //                     fontWeight: FontWeight.w600,
  //                     color: Colors.black87,
  //                   ),
  //                 ),
  //               ],
  //             ),
  //             const SizedBox(height: 16),
  //             const Text(
  //               'Would you like to take another measurement or save this lipid profile?',
  //               style: TextStyle(fontSize: 16, color: Colors.grey),
  //               textAlign: TextAlign.center,
  //             ),
  //             const SizedBox(height: 16),
  //             Row(
  //               children: [
  //                 Expanded(
  //                   child: ElevatedButton.icon(
  //                     onPressed: _isSaving ? null : _takeAnotherLipidReading,
  //                     icon: const Icon(Icons.refresh, color: Colors.white),
  //                     label: Text(
  //                       'Take Another Reading',
  //                       style: const TextStyle(
  //                         fontWeight: FontWeight.bold,
  //                       ),
  //                     ),
  //                     style: ElevatedButton.styleFrom(
  //                       backgroundColor: Colors.orange,
  //                       foregroundColor: Colors.white,
  //                       padding: const EdgeInsets.symmetric(vertical: 12),
  //                       shape: RoundedRectangleBorder(
  //                         borderRadius: BorderRadius.circular(8),
  //                       ),
  //                     ),
  //                   ),
  //                 ),
  //                 const SizedBox(width: 12),
  //                 Expanded(
  //                   child: ElevatedButton.icon(
  //                     onPressed: _isSaving ? null : _saveLipidMeasurements,
  //                     icon: _isSaving
  //                         ? const SizedBox(
  //                             width: 20,
  //                             height: 20,
  //                             child: CircularProgressIndicator(
  //                               strokeWidth: 2,
  //                               valueColor:
  //                                   AlwaysStoppedAnimation(Colors.white),
  //                             ),
  //                           )
  //                         : const Icon(Icons.save, color: Colors.white),
  //                     label: Text(
  //                       _isSaving ? 'Saving...' : 'Save & Continue',
  //                       style: const TextStyle(
  //                         fontWeight: FontWeight.bold,
  //                       ),
  //                     ),
  //                     style: ElevatedButton.styleFrom(
  //                       backgroundColor: _primaryBlue,
  //                       foregroundColor: Colors.white,
  //                       padding: const EdgeInsets.symmetric(vertical: 12),
  //                       shape: RoundedRectangleBorder(
  //                         borderRadius: BorderRadius.circular(8),
  //                       ),
  //                     ),
  //                   ),
  //                 ),
  //               ],
  //             ),
  //           ],
  //         ),
  //       ),
  //     ),
  //   );
  // }

  void _takeAnotherLipidReading() {
    if (!_disposed) {
      setStateIfMounted(() {
        _isSaved = false;
        // Clear current measurements to take new ones
        totalCholesterol = null;
        hdlCholesterol = null;
        ldlCholesterol = null;
        triglycerides = null;
      });
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
            'Ready to take another lipid profile measurement. Insert new test strip.'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 3),
      ),
    );
  }

  Future<void> _saveLipidMeasurements() async {
    if (!_hasAnyMeasurements()) return;

    // Prevent duplicate saves - if already saved or currently saving, don't proceed
    if (_isSaved) {
      debugPrint('⚠️ Lipid measurements already saved, ignoring duplicate save request');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lipid measurements already saved!'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    if (_isSaving) {
      debugPrint('⚠️ Lipid save already in progress, ignoring duplicate save request');
      return;
    }

    if (!_disposed) {
      setStateIfMounted(() {
        _isSaving = true;
      });
    }

    try {
      // Get real session and authentication data
      final sessionId = DeviceApiService.getCurrentSessionId();
      final authToken = DeviceApiService.getCurrentAuthToken();

      if (sessionId == null) {
        throw Exception(
            'No active session found. Please restart the measurement session.');
      }

      if (authToken == null) {
        throw Exception('Authentication token not found. Please log in again.');
      }

      // Use current patient ID from DeviceApiService to avoid stale patient ID issues (404 errors)
      final currentPatientId = DeviceApiService.getCurrentPatientId() ?? widget.patientId;
      if (currentPatientId == null) {
        throw Exception('Patient ID is required to save measurements.');
      }

      debugPrint('🩸 Saving lipid measurements for patient: $currentPatientId');

      // Prepare lipid data for API - convert String? values to double?
      final lipidData = <String, dynamic>{};

      if (totalCholesterol != null && _isNumeric(totalCholesterol!)) {
        lipidData['tc'] = double.parse(totalCholesterol!);
      }
      if (hdlCholesterol != null && _isNumeric(hdlCholesterol!)) {
        lipidData['hdl'] = double.parse(hdlCholesterol!);
      }
      if (ldlCholesterol != null && _isNumeric(ldlCholesterol!)) {
        lipidData['ldl'] = double.parse(ldlCholesterol!);
      }
      if (triglycerides != null && _isNumeric(triglycerides!)) {
        lipidData['tg'] = double.parse(triglycerides!);
      }

      if (lipidData.isEmpty) {
        throw Exception('No valid numeric measurements to save');
      }

      // Save lipid measurements via API
      final result = await DeviceApiService.saveLipidMeasurements(
        sessionId: sessionId,
        patientId: currentPatientId,
        lipidData: lipidData,
        token: authToken,
        measuredAt: DateTime.now(),
      );

      if (result != null && result.isNotEmpty) {
        if (!_disposed) {
          setStateIfMounted(() {
            _isSaved = true;
            _isSaving = false;
          });

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Blood lipid saved successfully!'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );

          // Navigate back to dashboard after delay with success result
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) {
              Navigator.of(context)
                  .pop(true); // Return true to indicate successful measurement
            }
          });
        }
      } else {
        throw Exception('Failed to save lipid measurements');
      }
    } catch (e) {
      if (!_disposed) {
        setStateIfMounted(() {
          _isSaving = false;
        });
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error saving blood lipid: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  bool _isNumeric(String value) {
    return double.tryParse(value) != null;
  }
}
