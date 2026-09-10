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
import 'package:share_plus/share_plus.dart';

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

// ---------------------------------------------------------------------------
// FILTERS
// ---------------------------------------------------------------------------

enum ScanFilter { color, enhanced, grayscale, blackWhite }

extension ScanFilterX on ScanFilter {
  String get label {
    switch (this) {
      case ScanFilter.color:
        return 'Color';
      case ScanFilter.enhanced:
        return 'Enhanced';
      case ScanFilter.grayscale:
        return 'Gray';
      case ScanFilter.blackWhite:
        return 'B&W';
    }
  }

  IconData get icon {
    switch (this) {
      case ScanFilter.color:
        return Icons.palette;
      case ScanFilter.enhanced:
        return Icons.auto_fix_high;
      case ScanFilter.grayscale:
        return Icons.gradient;
      case ScanFilter.blackWhite:
        return Icons.contrast;
    }
  }
}

class ScanPage {
  Uint8List original;
  Uint8List current;
  ScanFilter filter;

  ScanPage(this.original) : current = original, filter = ScanFilter.color;
}

class _FilterJob {
  final Uint8List bytes;
  final ScanFilter filter;
  const _FilterJob(this.bytes, this.filter);
}

Uint8List applyFilterSync(_FilterJob job) {
  if (job.filter == ScanFilter.color) return job.bytes;

  final decoded = img.decodeImage(job.bytes);
  if (decoded == null) return job.bytes;

  img.Image out;
  switch (job.filter) {
    case ScanFilter.color:
      out = decoded;
      break;
    case ScanFilter.enhanced:
      out = img.adjustColor(decoded, contrast: 1.35, saturation: 1.1);
      break;
    case ScanFilter.grayscale:
      out = img.grayscale(decoded);
      break;
    case ScanFilter.blackWhite:
      out = img.grayscale(decoded);
      out = img.adjustColor(out, contrast: 1.6);
      out = img.luminanceThreshold(out, threshold: 0.55);
      break;
  }

  return Uint8List.fromList(img.encodeJpg(out, quality: 92));
}

Future<Uint8List> applyFilter(Uint8List bytes, ScanFilter filter) {
  if (filter == ScanFilter.color) return Future.value(bytes);
  return compute(applyFilterSync, _FilterJob(bytes, filter));
}

// ---------------------------------------------------------------------------
// SCANNER SCREEN
// ---------------------------------------------------------------------------

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  CameraController? _controller;
  bool _isInitializing = true;
  bool _isCameraMode = true;

  final List<ScanPage> _pages = [];
  int _currentPageIndex = 0;

  bool _isResumingCamera = false;
  bool _isProcessing = false;
  Key _cameraPreviewKey = UniqueKey();

  ScanPage get _currentPage => _pages[_currentPageIndex];

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
      _cameraPreviewKey = UniqueKey();
    });
    _resumeCamera();
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _takePicture() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      final XFile imageFile = await _controller!.takePicture();
      final Uint8List bytes = await imageFile.readAsBytes();

      if (!mounted) return;

      setState(() {
        _pages.add(ScanPage(bytes));
        _currentPageIndex = _pages.length - 1;
        _isCameraMode = false;
      });

      await _pauseCamera();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✓ Page ${_pages.length} captured!'),
          duration: const Duration(seconds: 2),
          action: SnackBarAction(
            label: 'SCAN ANOTHER',
            textColor: Colors.yellow,
            onPressed: _switchToCameraMode,
          ),
        ),
      );
    } catch (e) {
      _showMsg('Capture failed: $e');
    }
  }

  Future<void> _setFilterForCurrent(ScanFilter filter) async {
    if (_pages.isEmpty || _isProcessing) return;
    final page = _currentPage;
    if (page.filter == filter) return;

    setState(() => _isProcessing = true);
    try {
      final result = await applyFilter(page.original, filter);
      if (!mounted) return;
      setState(() {
        page.current = result;
        page.filter = filter;
      });
    } catch (e) {
      _showMsg('Filter failed: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _applyCurrentFilterToAll() async {
    if (_pages.isEmpty || _isProcessing) return;
    final filter = _currentPage.filter;

    setState(() => _isProcessing = true);
    try {
      for (final page in _pages) {
        if (page.filter == filter) continue;
        page.current = await applyFilter(page.original, filter);
        page.filter = filter;
      }
      _showMsg('Applied "${filter.label}" to all pages');
    } catch (e) {
      _showMsg('Filter failed: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _cropCurrentPage() async {
    if (_pages.isEmpty || _isProcessing) return;

    final page = _currentPage;

    final Uint8List? cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => CropPage(imageBytes: page.original, aspectRatio: null),
      ),
    );

    if (cropped == null || !mounted) return;

    setState(() => _isProcessing = true);
    try {
      final filtered = await applyFilter(cropped, page.filter);
      if (!mounted) return;
      setState(() {
        page.original = cropped;
        page.current = filtered;
      });
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<Uint8List?> _generatePdfBytes() async {
    if (_pages.isEmpty) return null;

    final pdf = pw.Document();

    for (final page in _pages) {
      final pdfImage = pw.MemoryImage(page.current);
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (pw.Context context) {
            return pw.FullPage(
              ignoreMargins: true,
              child: pw.Image(pdfImage, fit: pw.BoxFit.contain),
            );
          },
        ),
      );
    }

    return pdf.save();
  }

  Future<void> _downloadPDF() async {
    final bytes = await _generatePdfBytes();
    if (bytes == null) return;

    try {
      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => bytes,
        name: 'Scanned_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
    } catch (e) {
      _showMsg('PDF Error: $e');
    }
  }

  Future<void> _sharePDF() async {
    final bytes = await _generatePdfBytes();
    if (bytes == null) return;

    try {
      final xfile = XFile.fromData(
        bytes,
        mimeType: 'application/pdf',
        name: 'Scanned_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      await Share.shareXFiles([xfile], text: 'Scanned document');
    } catch (e) {
      _showMsg('Share failed: $e');
    }
  }

  Future<void> _downloadCurrentPng() async {
    if (_pages.isEmpty) return;

    try {
      final pageNo = _currentPageIndex + 1;
      final ts = DateTime.now().millisecondsSinceEpoch;

      final decoded = img.decodeImage(_currentPage.current);
      if (decoded == null) {
        _showMsg('Could not decode image for PNG export.');
        return;
      }

      final pngBytes = Uint8List.fromList(img.encodePng(decoded));

      await FileSaver.instance.saveFile(
        name: 'Scanned_${ts}_page$pageNo',
        bytes: pngBytes,
        ext: 'png',
        mimeType: MimeType.png,
      );

      _showMsg('Saved PNG for page $pageNo');
    } catch (e) {
      _showMsg('PNG save failed: $e');
    }
  }

  Future<void> _downloadAllPngsAsZip() async {
    if (_pages.isEmpty) return;

    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final archive = Archive();

      for (int i = 0; i < _pages.length; i++) {
        final decoded = img.decodeImage(_pages[i].current);
        if (decoded == null) continue;
        final png = img.encodePng(decoded);
        archive.addFile(ArchiveFile('page_${i + 1}.png', png.length, png));
      }

      final zipped = ZipEncoder().encode(archive);
      if (zipped == null) throw Exception('ZIP encoding failed');

      await FileSaver.instance.saveFile(
        name: 'Scanned_${ts}_PNG_ALL',
        bytes: Uint8List.fromList(zipped),
        ext: 'zip',
        mimeType: MimeType.zip,
      );

      _showMsg('Saved ZIP (all pages as PNG).');
    } catch (e) {
      _showMsg('ZIP save failed: $e');
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
                _pages.removeAt(index);
                if (_pages.isEmpty) {
                  _switchToCameraMode();
                  _currentPageIndex = 0;
                } else if (_currentPageIndex >= _pages.length) {
                  _currentPageIndex = _pages.length - 1;
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
          _isCameraMode ? 'Scan Document' : 'Preview (${_pages.length} pages)',
        ),
        centerTitle: true,
        actions: [
          if (!_isCameraMode && _pages.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Share PDF',
              onPressed: _sharePDF,
            ),
            IconButton(
              icon: const Icon(Icons.crop),
              tooltip: 'Crop Current Page',
              onPressed: _isProcessing ? null : _cropCurrentPage,
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
                          _pages.clear();
                          _currentPageIndex = 0;
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
      bottomNavigationBar: (!_isCameraMode && _pages.isNotEmpty)
          ? _buildBottomBar()
          : null,
    );
  }

  Widget _buildBody() {
    if (_isCameraMode) return _buildCameraBody();

    if (_pages.isEmpty) {
      return const Center(child: Text('No pages scanned'));
    }

    return Column(
      children: [
        Expanded(
          flex: 3,
          child: Stack(
            children: [
              InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Container(
                  color: Colors.grey[200],
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        _currentPage.current,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                ),
              ),
              if (_isProcessing)
                Positioned.fill(
                  child: Container(
                    color: Colors.black38,
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
        _buildFilterBar(),
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
                      'Page ${_currentPageIndex + 1} / ${_pages.length}',
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
                          onPressed: _currentPageIndex < _pages.length - 1
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
                  itemCount: _pages.length,
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
                              _pages[index].current,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
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

  Widget _buildFilterBar() {
    final current = _currentPage.filter;
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: ScanFilter.values.map((f) {
                  final selected = f == current;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      avatar: Icon(f.icon, size: 18),
                      label: Text(f.label),
                      selected: selected,
                      onSelected: _isProcessing
                          ? null
                          : (_) => _setFilterForCurrent(f),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Apply "${current.label}" to all pages',
            icon: const Icon(Icons.done_all),
            onPressed: _isProcessing || _pages.length < 2
                ? null
                : _applyCurrentFilterToAll,
          ),
        ],
      ),
    );
  }

  Widget _buildCameraBody() {
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
        if (_pages.isNotEmpty)
          Positioned(
            top: 40,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.collections, size: 16, color: Colors.amber),
                  const SizedBox(width: 6),
                  Text(
                    '${_pages.length}',
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
                label: Text('SAVE PDF (${_pages.length})'),
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

// ---------------------------------------------------------------------------
// CROP PAGE (free size, web compatible)
// ---------------------------------------------------------------------------

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
