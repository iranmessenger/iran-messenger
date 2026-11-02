export 'platform/host.dart' show stripAndCompressPhoto;

String mimeForName(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.gif')) return 'image/gif';
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.webp')) return 'image/webp';
  if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
  if (n.endsWith('.mp4')) return 'video/mp4';
  if (n.endsWith('.mov')) return 'video/quicktime';
  if (n.endsWith('.webm')) return 'video/webm';
  if (n.endsWith('.3gp')) return 'video/3gpp';
  if (n.endsWith('.m4a')) return 'audio/mp4';
  return 'application/octet-stream';
}
