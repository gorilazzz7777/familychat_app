import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

Future<Uint8List> readPickedImageBytes(XFile file) => file.readAsBytes();
