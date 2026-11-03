import 'package:flutter/material.dart';

class DesktopSettingsDialog extends StatefulWidget {
  const DesktopSettingsDialog({super.key, required this.volume, required this.streamingQuality,
    required this.meteredQuality, required this.onVolumeChanged, required this.onQualityChanged,
    this.onLastFmSettings});
  final double volume;
  final int streamingQuality, meteredQuality;
  final ValueChanged<double> onVolumeChanged;
  final void Function(String key, int value) onQualityChanged;
  final VoidCallback? onLastFmSettings;

  @override
  State<DesktopSettingsDialog> createState() => _DesktopSettingsDialogState();
}

class _DesktopSettingsDialogState extends State<DesktopSettingsDialog> {
  late double _volume = widget.volume;
  late int _quality = widget.streamingQuality, _metered = widget.meteredQuality;

  Widget _qualityChoice(String label, int selected, ValueChanged<int> change) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Row(children: [
      Expanded(child: Text(label, style: const TextStyle(fontSize: 15))),
      DropdownButton<int>(value: selected >= 0 && selected <= 3 ? selected : null,
        hint: const Text('Choose quality'),
        items: const [
          DropdownMenuItem(value: 0, child: Text('Automatic')),
          DropdownMenuItem(value: 1, child: Text('Low')),
          DropdownMenuItem(value: 2, child: Text('Normal')),
          DropdownMenuItem(value: 3, child: Text('High')),
        ], onChanged: (value) { if (value != null) change(value); }),
    ]),
  );

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: const Color(0xff181818),
    child: SizedBox(width: 560, child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Settings', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold))),
          IconButton(tooltip: 'Close settings', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
        ]),
        const SizedBox(height: 28),
        const Text('Audio', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        Row(children: [
          const Expanded(child: Text('Volume', style: TextStyle(fontSize: 15))),
          Text('${(_volume * 100).round()}%', style: const TextStyle(color: Color(0xffb3b3b3))),
        ]),
        Slider(value: _volume, onChanged: (value) {
          setState(() => _volume = value);
          widget.onVolumeChanged(value);
        }),
        _qualityChoice('Streaming quality', _quality, (value) {
          widget.onQualityChanged('audio.play_bitrate_non_metered_enumeration', value);
          setState(() => _quality = value);
        }),
        _qualityChoice('On metered connections', _metered, (value) {
          widget.onQualityChanged('audio.play_bitrate_enumeration', value);
          setState(() => _metered = value);
        }),
        const SizedBox(height: 12),
        const Text('Changes are saved automatically.', style: TextStyle(color: Color(0xffb3b3b3), fontSize: 13)),
        const SizedBox(height: 28),
        const Text('Last.fm', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        const Text('Scrobbling uses the Spotify connection on your Last.fm account.',
          style: TextStyle(color: Color(0xffb3b3b3))),
        const SizedBox(height: 12),
        TextButton(onPressed: widget.onLastFmSettings, child: const Text('Manage Last.fm connection')),
      ]),
    )),
  );
}
