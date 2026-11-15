import 'package:flutter/material.dart';

class LikedSongsArtwork extends StatelessWidget {
  const LikedSongsArtwork({super.key});

  @override
  Widget build(BuildContext context) => const DecoratedBox(decoration: BoxDecoration(
    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
      colors: [Color(0xff450af5), Color(0xffc4efd9)])),
    child: Center(child: FractionallySizedBox(widthFactor: .42, heightFactor: .42,
      child: FittedBox(child: Icon(Icons.favorite, color: Colors.white)))));
}
