import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:camera/camera.dart';
import 'package:crop_your_image/crop_your_image.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera error: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Multi-Page Document Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const ScannerScreen(),
    );
  }
}

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  CameraController? _controller;
  bool _isInitializing = true;
  bool _isCameraMode = true;

  final List<Uint8List> _scannedPages = [];
  int _currentPageIndex = 0;

  bool _isResumingCamera = false;
  Key _cameraPreviewKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty) {
      if (mounted) setState(() => _isInitializing = false);
      return;
    }

    _controller = CameraController(
      cameras[0],
      ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await _controller!.initialize();
    } catch (e) {
      debugPrint('Error initializing camera: $e');
    }

    if (mounted) setState(() => _isInitializing = false);
  }

  Future<void> _pauseCamera() async {
    try {
      await _controller?.pausePreview();
    } catch (e) {
      debugPrint('Error pausing camera: $e');
    }
  }

  Future<void> _resumeCamera() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    setState(() => _isResumingCamera = true);
    try {
      await _controller?.pausePreview();
      await Future.delayed(const Duration(milliseconds: 100));
      await _controller?.resumePreview();
    } catch (e) {
      debugPrint('Error resuming camera: $e');
      await _reinitializeCamera();
    }

    if (mounted) setState(() => _isResumingCamera = false);
  }

  Future<void> _reinitializeCamera() async {
    await _controller?.dispose();
    await _initCamera();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _switchToCameraMode() {
    setState(() {
      _isCameraMode = true;
      _cameraPreviewKey = UniqueKey(); // avoid frozen preview
    });
    _resumeCamera();
  }

  Future<void> _takePicture() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      final XFile imageFile = await _controller!.takePicture();
      final Uint8List bytes = await imageFile.readAsBytes();

      if (!mounted) return;

      setState(() {
        _scannedPages.add(bytes);
        _currentPageIndex = _scannedPages.length - 1;
        _isCameraMode = false;
      });

      await _pauseCamera();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✓ Page ${_scannedPages.length} captured!'),
          duration: const Duration(seconds: 2),
          action: SnackBarAction(
            label: 'SCAN ANOTHER',
            textColor: Colors.yellow,
            onPressed: _switchToCameraMode,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Capture failed: $e')));
    }
  }

  Future<void> _downloadPDF() async {
    if (_scannedPages.isEmpty) return;

    try {
      final pdf = pw.Document();

      for (int i = 0; i < _scannedPages.length; i++) {
        final pdfImage = pw.MemoryImage(_scannedPages[i]);
        pdf.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            build: (pw.Context context) {
              return pw.FullPage(
                ignoreMargins: true,
                child: pw.Image(pdfImage, fit: pw.BoxFit.cover),
              );
            },
          ),
        );
      }

      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => pdf.save(),
        name: 'Scanned_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('PDF Error: $e')));
    }
  }

  /// Crop current page (FREE SIZE - not A4).
  Future<void> _cropCurrentPage() async {
    if (_scannedPages.isEmpty) return;

    final Uint8List original = _scannedPages[_currentPageIndex];

    final Uint8List? cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => CropPage(
          imageBytes: original,
          aspectRatio: null, // free crop (any size)
        ),
      ),
    );

    if (cropped == null || !mounted) return;

    setState(() {
      _scannedPages[_currentPageIndex] = cropped;
    });
  }

  /// Save ONLY the CURRENT page as PNG (reliable on web).
  Future<void> _downloadCurrentPng() async {
    if (_scannedPages.isEmpty) return;

    try {
      final pageNo = _currentPageIndex + 1;
      final ts = DateTime.now().millisecondsSinceEpoch;

      final decoded = img.decodeImage(_scannedPages[_currentPageIndex]);
      if (decoded == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not decode image for PNG export.'),
          ),
        );
        return;
      }

      final pngBytes = Uint8List.fromList(img.encodePng(decoded));

      await FileSaver.instance.saveFile(
        name: 'Scanned_${ts}_page$pageNo',
        bytes: pngBytes,
        ext: 'png',
        mimeType: MimeType.png,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved PNG for page $pageNo')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('PNG save failed: $e')));
    }
  }

  /// Save ALL pages as PNG inside a single ZIP file (best for Web).
  Future<void> _downloadAllPngsAsZip() async {
    if (_scannedPages.isEmpty) return;

    try {
      final ts = DateTime.now().millisecondsSinceEpoch;

      final archive = Archive();

      for (int i = 0; i < _scannedPages.length; i++) {
        final decoded = img.decodeImage(_scannedPages[i]);
        if (decoded == null) continue;

        final png = img.encodePng(decoded); // List<int>
        final filename = 'page_${i + 1}.png';

        archive.addFile(ArchiveFile(filename, png.length, png));
      }

      final zipped = ZipEncoder().encode(archive);
      if (zipped == null) {
        throw Exception('ZIP encoding failed');
      }

      await FileSaver.instance.saveFile(
        name: 'Scanned_${ts}_PNG_ALL',
        bytes: Uint8List.fromList(zipped),
        ext: 'zip',
        mimeType: MimeType.zip, // if this fails in your version, tell me
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved ZIP (all pages as PNG).')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ZIP save failed: $e')));
    }
  }

  void _deletePage(int index) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Page?'),
        content: Text('Remove page ${index + 1}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _scannedPages.removeAt(index);
                if (_scannedPages.isEmpty) {
                  _switchToCameraMode();
                  _currentPageIndex = 0;
                } else if (_currentPageIndex >= _scannedPages.length) {
                  _currentPageIndex = _scannedPages.length - 1;
                }
              });
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isCameraMode
              ? 'Scan Document'
              : 'Preview (${_scannedPages.length} pages)',
        ),
        centerTitle: true,
        actions: [
          if (!_isCameraMode && _scannedPages.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.crop),
              tooltip: 'Crop Current Page',
              onPressed: _cropCurrentPage,
            ),
            IconButton(
              icon: const Icon(Icons.folder_zip),
              tooltip: 'Save ALL as ZIP (PNG)',
              onPressed: _downloadAllPngsAsZip,
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear All',
              onPressed: () => showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Clear All Pages?'),
                  content: const Text('This will delete all scans.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        setState(() {
                          _scannedPages.clear();
                          _switchToCameraMode();
                        });
                      },
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Delete All'),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.photo_camera),
              tooltip: 'Add New Page',
              onPressed: _switchToCameraMode,
            ),
          ],
        ],
      ),
      body: _buildBody(),
      floatingActionButton: _isCameraMode && !_isResumingCamera
          ? FloatingActionButton.large(
              onPressed: _takePicture,
              backgroundColor: Colors.white,
              child: Icon(
                Icons.camera_alt,
                size: 36,
                color: Theme.of(context).primaryColor,
              ),
            )
          : null,
      bottomNavigationBar: (!_isCameraMode && _scannedPages.isNotEmpty)
          ? _buildBottomBar()
          : null,
    );
  }

  Widget _buildBody() {
    // CAMERA MODE
    if (_isCameraMode) {
      if (_isInitializing || _isResumingCamera) {
        return Container(
          color: Colors.black,
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 16),
                Text(
                  'Starting Camera...',
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        );
      }

      if (cameras.isEmpty ||
          _controller == null ||
          !_controller!.value.isInitialized) {
        return Center(
          child: Text(
            kIsWeb
                ? 'No camera detected (Web needs camera permission).'
                : 'No camera detected',
          ),
        );
      }

      return Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CameraPreview(_controller!, key: _cameraPreviewKey),
          ),
          if (_scannedPages.isNotEmpty)
            Positioned(
              top: 40,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.collections,
                      size: 16,
                      color: Colors.amber,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${_scannedPages.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const Positioned(
            bottom: 100,
            child: Text(
              'TAP BUTTON TO CAPTURE',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
                letterSpacing: 1,
              ),
            ),
          ),
        ],
      );
    }

    // PREVIEW MODE
    if (_scannedPages.isEmpty) {
      return const Center(child: Text('No pages scanned'));
    }

    return Column(
      children: [
        Expanded(
          flex: 3,
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: Container(
              color: Colors.grey[200],
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    _scannedPages[_currentPageIndex],
                    fit: BoxFit.contain, // not forcing A4
                  ),
                ),
              ),
            ),
          ),
        ),
        Container(
          height: 140,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black12)],
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Page ${_currentPageIndex + 1} / ${_scannedPages.length}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left),
                          onPressed: _currentPageIndex > 0
                              ? () => setState(() => _currentPageIndex--)
                              : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right),
                          onPressed:
                              _currentPageIndex < _scannedPages.length - 1
                              ? () => setState(() => _currentPageIndex++)
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _scannedPages.length,
                  itemBuilder: (context, index) {
                    final isSelected = index == _currentPageIndex;
                    return GestureDetector(
                      onTap: () => setState(() => _currentPageIndex = index),
                      child: Container(
                        width: 90,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isSelected
                                ? Colors.indigo
                                : Colors.grey.shade300,
                            width: isSelected ? 3 : 1,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.memory(
                              _scannedPages[index],
                              fit: BoxFit.cover,
                            ),
                            Positioned(
                              top: 2,
                              right: 2,
                              child: GestureDetector(
                                onTap: () => _deletePage(index),
                                child: const CircleAvatar(
                                  radius: 10,
                                  backgroundColor: Colors.red,
                                  child: Icon(
                                    Icons.close,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        boxShadow: const [BoxShadow(blurRadius: 10, color: Colors.black12)],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _switchToCameraMode,
                icon: const Icon(Icons.add_a_photo),
                label: const Text('ADD PAGE'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _downloadCurrentPng,
                icon: const Icon(Icons.image),
                label: Text('SAVE PNG (${_currentPageIndex + 1})'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: _downloadPDF,
                icon: const Icon(Icons.picture_as_pdf),
                label: Text('SAVE PDF (${_scannedPages.length})'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Web-compatible crop screen using crop_your_image.
/// No A4 ratio => free size crop.
class CropPage extends StatefulWidget {
  final Uint8List imageBytes;
  final double? aspectRatio;

  const CropPage({super.key, required this.imageBytes, this.aspectRatio});

  @override
  State<CropPage> createState() => _CropPageState();
}

class _CropPageState extends State<CropPage> {
  final CropController _cropController = CropController();
  bool _isCropping = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crop'),
        actions: [
          TextButton(
            onPressed: _isCropping
                ? null
                : () {
                    setState(() => _isCropping = true);
                    _cropController.crop();
                  },
            child: Text(
              _isCropping ? '...' : 'DONE',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: Container(
        color: Colors.black,
        child: Crop(
          controller: _cropController,
          image: widget.imageBytes,
          aspectRatio: widget.aspectRatio,
          onCropped: (CropResult result) {
            if (result is CropSuccess) {
              Navigator.of(context).pop(result.croppedImage);
            } else {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Crop failed')));
              Navigator.of(context).pop();
            }
          },
        ),
      ),
    );
  }
}
