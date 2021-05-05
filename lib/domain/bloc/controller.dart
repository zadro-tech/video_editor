import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_ffmpeg/statistics.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_ffmpeg/flutter_ffmpeg.dart';

import 'package:video_editor/domain/entities/crop_style.dart';
import 'package:video_editor/domain/entities/trim_style.dart';

enum RotateDirection { left, right }

///A preset is a collection of options that will provide a certain encoding speed to compression ratio.
///
///A slower preset will provide better compression (compression is quality per filesize).
///
///This means that, for example, if you target a certain file size or constant bit rate,
///you will achieve better quality with a slower preset.
///Similarly, for constant quality encoding,
///you will simply save bitrate by choosing a slower preset.
enum VideoExportPreset {
  none,
  ultrafast,
  superfast,
  veryfast,
  faster,
  fast,
  medium,
  slow,
  slower,
  veryslow
}

///_max = Offset(1.0, 1.0);
const Offset _max = Offset(1.0, 1.0);

///_min = Offset.zero;
const Offset _min = Offset.zero;

class VideoEditorController extends ChangeNotifier {
  ///Style for [TrimSlider]
  final TrimSliderStyle trimStyle;

  ///Style for [CropGridViewer]
  final CropGridStyle cropStyle;

  ///Video from [File].
  final File file;

  ///Constructs a [VideoEditorController] that edits a video from a file.
  VideoEditorController.file(
    this.file, {
    TrimSliderStyle? trimStyle,
    CropGridStyle? cropStyle,
  })  : _video = VideoPlayerController.file(file),
        this.cropStyle = cropStyle ?? CropGridStyle(),
        this.trimStyle = trimStyle ?? TrimSliderStyle();

  FlutterFFmpeg _ffmpeg = FlutterFFmpeg();
  FlutterFFprobe _ffprobe = FlutterFFprobe();

  int _rotation = 0;
  bool isTrimming = false;
  bool isCropping = false;

  double? _preferredCropAspectRatio;

  double _minTrim = _min.dx;
  double _maxTrim = _max.dx;

  Offset _minCrop = _min;
  Offset _maxCrop = _max;

  Offset cacheMinCrop = _min;
  Offset cacheMaxCrop = _max;

  Duration _trimEnd = Duration.zero;
  Duration _trimStart = Duration.zero;
  VideoPlayerController _video;

  int _videoWidth = 0;
  int _videoHeight = 0;

  ///Get the `VideoPlayerController`
  VideoPlayerController get video => _video;

  ///Get the [Rotation Degrees]
  int get rotation => _rotation;

  ///Get the `VideoPlayerController.value.initialized`
  bool get initialized => _video.value.isInitialized;

  ///Get the `VideoPlayerController.value.isPlaying`
  bool get isPlaying => _video.value.isPlaying;

  ///Get the `VideoPlayerController.value.position`
  Duration get videoPosition => _video.value.position;

  ///Get the `VideoPlayerController.value.duration`
  Duration get videoDuration => _video.value.duration;

  ///Get the [Video Dimension] like VideoWidth and VideoHeight
  Size get videoDimension =>
      Size(_videoWidth.toDouble(), _videoHeight.toDouble());

  ///The **MinTrim** (Range is `0.0` to `1.0`).
  double get minTrim => _minTrim;
  set minTrim(double value) {
    if (value >= _min.dx && value <= _max.dx) {
      _minTrim = value;
      _updateTrimRange();
    }
  }

  ///The **MaxTrim** (Range is `0.0` to `1.0`).
  double get maxTrim => _maxTrim;
  set maxTrim(double value) {
    if (value >= _min.dx && value <= _max.dx) {
      _maxTrim = value;
      _updateTrimRange();
    }
  }

  ///The **TopLeft Offset** (Range is `Offset(0.0, 0.0)` to `Offset(1.0, 1.0)`).
  Offset get minCrop => _minCrop;
  set minCrop(Offset value) {
    if (value >= _min && value <= _max) {
      _minCrop = value;
      notifyListeners();
    }
  }

  ///The **BottomRight Offset** (Range is `Offset(0.0, 0.0)` to `Offset(1.0, 1.0)`).
  Offset get maxCrop => _maxCrop;
  set maxCrop(Offset value) {
    if (value >= _min && value <= _max) {
      _maxCrop = value;
      notifyListeners();
    }
  }

  double? get preferredCropAspectRatio => _preferredCropAspectRatio;
  set preferredCropAspectRatio(double? value) {
    if (value == null) {
      _preferredCropAspectRatio = value;
      notifyListeners();
    } else if (value >= 0) {
      final length = cropStyle.boundariesLength * 4;
      final videoWidth = videoDimension.width;
      final videoHeight = videoDimension.height;
      final cropHeight = (cacheMaxCrop.dy - cacheMinCrop.dy) * videoHeight;
      final cropWidth = (cacheMaxCrop.dx - cacheMinCrop.dx) * videoWidth;
      Offset newMax = Offset(
        cropWidth / videoWidth,
        (cropWidth / value) / videoWidth,
      );

      if (newMax.dy > _max.dy || newMax.dx > _max.dx) {
        newMax = Offset(
          (cropHeight * value) / cropHeight,
          cropHeight / videoHeight,
        );
      }

      if ((newMax.dx - cacheMinCrop.dx) * videoWidth > length &&
          (newMax.dy - cacheMinCrop.dy) * videoHeight > length) {
        cacheMaxCrop = newMax;
        _preferredCropAspectRatio = value;
        notifyListeners();
      }
    }
  }

  //----------------//
  //VIDEO CONTROLLER//
  //----------------//
  ///Attempts to open the given [File] and load metadata about the video.
  Future<void> initialize() async {
    await _video.initialize();
    await _getVideoDimensions();
    _video.addListener(_videoListener);
    _video.setLooping(true);
    _updateTrimRange();
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    if (_video.value.isPlaying) await _video.pause();
    _video.removeListener(_videoListener);
    final executions = await _ffmpeg.listExecutions();
    if (executions.length > 0) await _ffmpeg.cancel();
    _video.dispose();
    super.dispose();
  }

  void _videoListener() {
    final position = videoPosition;
    if (position < _trimStart || position >= _trimEnd)
      _video.seekTo(_trimStart);
  }

  //----------//
  //VIDEO CROP//
  //----------//
  Future<String> _getCrop() async {
    await _getVideoDimensions();
    int enddx = (_videoWidth * maxCrop.dx).floor();
    int enddy = (_videoHeight * maxCrop.dy).floor();
    int startdx = (_videoWidth * minCrop.dx).floor();
    int startdy = (_videoHeight * minCrop.dy).floor();

    if (enddx > _videoWidth) enddx = _videoWidth;
    if (enddy > _videoHeight) enddy = _videoHeight;
    if (startdx < 0) startdx = 0;
    if (startdy < 0) startdy = 0;
    return "crop=${enddx - startdx}:${enddy - startdy}:$startdx:$startdy";
  }

  ///Update the [minCrop] and [maxCrop]
  void updateCrop() {
    minCrop = cacheMinCrop;
    maxCrop = cacheMaxCrop;
  }

  //----------//
  //VIDEO TRIM//
  //----------//
  void _updateTrimRange() {
    final duration = videoDuration;
    _trimStart = duration * minTrim;
    _trimEnd = duration * maxTrim;
    notifyListeners();
  }

  ///Get the **VideoPosition** (Range is `0.0` to `1.0`).
  double get trimPosition =>
      videoPosition.inMilliseconds / videoDuration.inMilliseconds;

  //------------//
  //VIDEO ROTATE//
  //------------//
  void rotate90Degrees([RotateDirection direction = RotateDirection.right]) {
    switch (direction) {
      case RotateDirection.left:
        _rotation += 90;
        if (_rotation >= 360) _rotation = _rotation - 360;
        break;
      case RotateDirection.right:
        _rotation -= 90;
        if (_rotation <= 0) _rotation = 360 + _rotation;
        break;
    }
    notifyListeners();
  }

  String _getRotation() {
    List<String> transpose = [];
    for (int i = 0; i < _rotation / 90; i++) transpose.add("transpose=2");
    return transpose.length > 0 ? "${transpose.join(',')}" : "";
  }

  //------------//
  //VIDEO EXPORT//
  //------------//
  Future<void> _getVideoDimensions() async {
    if (!(_videoHeight > 0 && _videoWidth > 0)) {
      final info = await _ffprobe.getMediaInformation(file.path);
      final streams = info.getStreams();
      int _height = 0;
      int _width = 0;

      if (streams != null && streams.length > 0) {
        for (var stream in streams) {
          final width = stream.getAllProperties()['width'];
          final height = stream.getAllProperties()['height'];
          final metadataMap = stream.getAllProperties()['side_data_list'];
            if (metadataMap != null) {
                for (var metadata in metadataMap) {
                    if (metadata.containsKey('rotation')) {
                        int rotate = metadata['rotation'];
                        var rotateTimes = rotate / 90;
                        if (rotateTimes % 2 != 0) {
                            width = stream.getAllProperties()['height'];
                            height = stream.getAllProperties()['width'];
                        }
                    }
                }
            }
          if (width != null && width > _width) _width = width;
          if (height != null && height > _height) _height = height;
        }
      }

      _videoHeight = _height;
      _videoWidth = _width;
    }
  }

  ///Export the video at `TemporaryDirectory` and return a `File`.
  ///
  ///
  ///If the [name] is `null`, then it uses the filename.
  ///
  ///
  ///The [scale] is `scale=width*scale:height*scale` and reduce o increase video size.
  ///
  ///The [onProgress] is called while the video is exporting. This argument is usually used to update the export progress percentage.
  ///
  ///The [preset] is the `compress quality` **(Only available on min-gpl-lts package)**.
  ///A slower preset will provide better compression (compression is quality per filesize).
  ///**More info about presets**:  https://ffmpeg.org/ffmpeg-formats.htmlhttps://trac.ffmpeg.org/wiki/Encode/H.264
  Future<File?> exportVideo({
    String? name,
    String format = "mp4",
    double scale = 1.0,
    String? customInstruction,
    void Function(Statistics)? onProgress,
    VideoExportPreset preset = VideoExportPreset.none,
  }) async {
    final FlutterFFmpegConfig _config = FlutterFFmpegConfig();
    final String tempPath = (await getTemporaryDirectory()).path;
    final String videoPath = file.path;
    if (name == null) name = path.basename(videoPath).split('.')[0];
    final String outputPath = tempPath + name + ".$format";

    //-----------------//
    //CALCULATE FILTERS//
    //-----------------//
    final String gif = format != "gif" ? "" : "fps=10 -loop 0";
    final String trim = minTrim >= _min.dx && maxTrim <= _max.dx
        ? "-ss $_trimStart -to $_trimEnd"
        : "";
    final String crop =
        minCrop >= _min && maxCrop <= _max ? await _getCrop() : "";
    final String rotation =
        _rotation >= 360 || _rotation <= 0 ? "" : _getRotation();
    final String scaleInstruction =
        scale == 1.0 ? "" : "scale=iw*$scale:ih*$scale";

    //----------------//
    //VALIDATE FILTERS//
    //----------------//
    final List<String> filters = [crop, scaleInstruction, rotation, gif];
    filters.removeWhere((item) => item.isEmpty);
    final String filter =
        filters.isNotEmpty ? "-filter:v " + filters.join(",") : "";
    final String execute =
        " -i $videoPath ${customInstruction ?? ""} $filter ${_getPreset(preset)} $trim -y $outputPath";

    //------------------//
    //PROGRESS CALLBACKS//
    //------------------//
    if (onProgress != null) _config.enableStatisticsCallback(onProgress);
    final int code = await _ffmpeg.execute(execute);
    _config.enableStatisticsCallback(null);

    //------//
    //RESULT//
    //------//
    if (code == 0) {
      print("SUCCESS EXPORT AT $outputPath");
      return File(outputPath);
    } else if (code == 255) {
      print("USER CANCEL EXPORT");
      return null;
    } else {
      print("ERROR ON EXPORT VIDEO (CODE $code)");
      return null;
    }
  }

  String _getPreset(VideoExportPreset preset) {
    String newPreset = "medium";

    switch (preset) {
      case VideoExportPreset.ultrafast:
        newPreset = "ultrafast";
        break;
      case VideoExportPreset.superfast:
        newPreset = "superfast";
        break;
      case VideoExportPreset.veryfast:
        newPreset = "veryfast";
        break;
      case VideoExportPreset.faster:
        newPreset = "faster";
        break;
      case VideoExportPreset.fast:
        newPreset = "fast";
        break;
      case VideoExportPreset.medium:
        newPreset = "medium";
        break;
      case VideoExportPreset.slow:
        newPreset = "slow";
        break;
      case VideoExportPreset.slower:
        newPreset = "slower";
        break;
      case VideoExportPreset.veryslow:
        newPreset = "veryslow";
        break;
      case VideoExportPreset.none:
        break;
    }

    return preset == VideoExportPreset.none ? "" : "-preset $newPreset";
  }
}
