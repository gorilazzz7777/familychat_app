/// Minimal dart:io surface for TDLib on platforms without dart:io (web).
library;

class Platform {
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static String get operatingSystem => 'web';
  static String get operatingSystemVersion => '';
}

class FileSystemEntity {
  const FileSystemEntity();
}

class File extends FileSystemEntity {
  File(this.path);

  final String path;

  bool existsSync() => false;

  int lengthSync() => 0;

  Future<bool> exists() async => false;

  Future<void> writeAsString(String contents) async {}

  Future<void> writeAsBytes(List<int> bytes, {bool flush = false}) async {}

  Future<String> readAsString() async => '';

  Future<List<int>> readAsBytes() async => const [];

  Future<FileSystemEntity> delete({bool recursive = false}) async => this;
}

class Directory extends FileSystemEntity {
  Directory(this.path);

  final String path;

  Future<bool> exists() async => false;

  Future<Directory> create({bool recursive = false}) async => this;

  Future<FileSystemEntity> delete({bool recursive = false}) async => this;
}
