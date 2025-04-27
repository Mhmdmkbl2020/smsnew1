import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:crypto/crypto.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _requestPermissions();
  runApp(const BLEFileReceiverApp());
}

Future<void> _requestPermissions() async {
  final permissions = await [
    Permission.bluetooth,
    Permission.bluetoothConnect,
    Permission.bluetoothScan,
    Permission.storage,
    Permission.manageExternalStorage,
    if (Platform.isAndroid) Permission.locationWhenInUse,
    if (Platform.isAndroid) Permission.accessBackgroundLocation,
  ].request();

  if (permissions[Permission.locationWhenInUse]?.isPermanentlyDenied ?? false) {
    await openAppSettings();
  }
}

class BLEFileReceiverApp extends StatelessWidget {
  const BLEFileReceiverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'نظام استقبال الملفات اللاسلكي',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const DeviceScanScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class DeviceScanScreen extends StatefulWidget {
  const DeviceScanScreen({super.key});

  @override
  State<DeviceScanScreen> createState() => _DeviceScanScreenState();
}

class _DeviceScanScreenState extends State<DeviceScanScreen> {
  final List<BluetoothDevice> _devices = [];
  bool _isScanning = false;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  @override
  void dispose() {
    _scanSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    try {
      setState(() {
        _isScanning = true;
        _devices.clear();
      });

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        _updateDeviceList(results);
      }, onError: (e) => _showError('Scan Error: ${e.toString()}'));

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 20),
        androidUsesFineLocation: true,
        removeIfGone: const Duration(seconds: 5),
      );
    } catch (e) {
      _showError('Failed to start scan: ${e.toString()}');
    }
  }

  void _updateDeviceList(List<ScanResult> results) {
    final uniqueDevices = results
        .where((r) => r.device.name.isNotEmpty)
        .map((r) => r.device)
        .toSet()
        .toList();

    if (mounted) {
      setState(() => _devices
        ..clear()
        ..addAll(uniqueDevices));
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.redAccent,
        ),
      );
      setState(() => _isScanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الأجهزة القريبة'),
        actions: [
          IconButton(
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: _isScanning
                  ? const Icon(Icons.bluetooth_disabled)
                  : const Icon(Icons.bluetooth_searching),
            onPressed: _isScanning ? FlutterBluePlus.stopScan : _startScan,
          )
        ],
      ),
      body: _buildDeviceList(),
    );
  }

  Widget _buildDeviceList() {
    if (_devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bluetooth_audio, size: 80, color: Colors.blueGrey),
            const SizedBox(height: 20),
            Text(
              _isScanning ? 'جاري البحث عن الأجهزة...' : 'اضغط زر البحث لبدء المسح',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _devices.length,
      separatorBuilder: (_, __) => const Divider(height: 24),
      itemBuilder: (_, index) => _buildDeviceTile(_devices[index]),
    );
  }

  Widget _buildDeviceTile(BluetoothDevice device) {
    return Card(
      elevation: 4,
      child: ListTile(
        leading: const Icon(Icons.device_hub, size: 40),
        title: Text(device.name),
        subtitle: Text(
          'إشارة: ${device.rssi} dBm\nID: ${device.remoteId}',
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        trailing: const Icon(Icons.arrow_forward),
        onTap: () => _navigateToTransferScreen(device),
      ),
    );
  }

  void _navigateToTransferScreen(BluetoothDevice device) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FileTransferScreen(device: device),
        fullscreenDialog: true,
      ),
    );
  }
}

class FileTransferScreen extends StatefulWidget {
  final BluetoothDevice device;

  const FileTransferScreen({super.key, required this.device});

  @override
  State<FileTransferScreen> createState() => _FileTransferScreenState();
}

class _FileTransferScreenState extends State<FileTransferScreen> {
  static const _serviceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  static const _rxCharUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';
  
  final _buffer = BytesBuilder();
  final List<File> _receivedFiles = [];
  bool _isReceiving = false;
  String _status = 'جاري الإعداد...';
  double _progress = 0.0;
  StreamSubscription<List<int>>? _dataSubscription;
  BluetoothCharacteristic? _rxCharacteristic;

  @override
  void initState() {
    super.initState();
    _initializeConnection();
  }

  @override
  void dispose() {
    _dataSubscription?.cancel();
    widget.device.disconnect();
    super.dispose();
  }

  Future<void> _initializeConnection() async {
    try {
      await _connectToDevice();
      await _discoverServices();
      _setupDataStream();
      setState(() => _status = 'جاهز لاستقبال الملفات');
    } catch (e) {
      _handleError(e);
    }
  }

  Future<void> _connectToDevice() async {
    try {
      await widget.device.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 15),
        requestMtu: 512,
      );
      await widget.device.requestMtu(512);
    } on Exception catch (e) {
      throw Exception('فشل الاتصال: ${e.toString()}');
    }
  }

  Future<void> _discoverServices() async {
    try {
      final services = await widget.device.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == Guid(_serviceUuid),
        orElse: () => throw Exception('الخدمة غير موجودة'),
      );

      _rxCharacteristic = service.characteristics.firstWhere(
        (c) => c.uuid == Guid(_rxCharUuid),
        orElse: () => throw Exception('خاصية الاستقبال غير موجودة'),
      );

      await _rxCharacteristic!.setNotifyValue(true);
    } on Exception catch (e) {
      throw Exception('فشل الاكتشاف: ${e.toString()}');
    }
  }

  void _setupDataStream() {
    _dataSubscription = _rxCharacteristic!.value.listen((data) {
      if (data.isEmpty) return;
      _processIncomingData(data);
    });
  }

  void _processIncomingData(List<int> data) {
    try {
      if (_isStartSignal(data)) {
        _startFileTransfer();
        return;
      }

      if (_isEndSignal(data)) {
        _finalizeFileTransfer();
        return;
      }

      if (_isReceiving) {
        _buffer.add(data);
        _updateProgress();
      }
    } catch (e) {
      _handleError(e);
    }
  }

  bool _isStartSignal(List<int> data) => data.first == 0x02 && !_isReceiving;
  bool _isEndSignal(List<int> data) => data.last == 0x03 && _isReceiving;

  void _startFileTransfer() {
    setState(() {
      _isReceiving = true;
      _buffer.clear();
      _status = 'جاري استقبال البيانات...';
      _progress = 0.0;
    });
  }

  void _updateProgress() {
    final mbReceived = _buffer.length / (1024 * 1024);
    setState(() {
      _progress = mbReceived.clamp(0.0, 1.0);
      _status = 'مستقبل: ${mbReceived.toStringAsFixed(2)} ميجابايت';
    });
  }

  Future<void> _finalizeFileTransfer() async {
    try {
      final file = await _saveReceivedFile();
      _verifyFileIntegrity(file);
      
      setState(() {
        _isReceiving = false;
        _receivedFiles.add(file);
        _status = 'تم الاستلام: ${file.path.split('/').last}';
        _progress = 1.0;
      });

      await Future.delayed(const Duration(seconds: 2));
      setState(() => _progress = 0.0);
    } catch (e) {
      _handleError(e);
    }
  }

  Future<File> _saveReceivedFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${directory.path}/received_file_$timestamp.bin';
      
      return await File(filePath).writeAsBytes(_buffer.toBytes());
    } on Exception catch (e) {
      throw Exception('فشل الحفظ: ${e.toString()}');
    }
  }

  void _verifyFileIntegrity(File file) {
    final bytes = file.readAsBytesSync();
    if (bytes.isEmpty) throw Exception('الملف فارغ');
    
    final hash = sha256.convert(bytes).toString();
    if (hash != _extractFileHash(bytes)) {
      throw Exception('الملف تالف: تباين في البصمة الرقمية');
    }
  }

  String _extractFileHash(List<int> bytes) {
    try {
      return String.fromCharCodes(bytes.sublist(bytes.length - 64));
    } on RangeError {
      throw Exception('تنسيق ملف غير صحيح');
    }
  }

  void _handleError(dynamic error) {
    setState(() {
      _isReceiving = false;
      _status = 'خطأ: ${error.toString().split(':').first}';
      _progress = 0.0;
    });
    _buffer.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _resetConnection,
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildConnectionStatus(),
            const SizedBox(height: 24),
            _buildTransferProgress(),
            const SizedBox(height: 24),
            _buildReceivedFilesList(),
          ],
        ),
      ),
    );
  }
