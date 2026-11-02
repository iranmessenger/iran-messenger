import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../media_prepare.dart';
import '../platform/host.dart';
import '../theme.dart';
import 'common.dart';

/// A silent, endlessly looping clip. Telegram "GIFs" are really MP4 files,
/// so animated items that are videos are shown this way.
class LoopingVideo extends StatefulWidget {
  const LoopingVideo({
    super.key,
    required this.path,
    required this.mime,
    this.play = true,
  });
  final String path;
  final String mime;
  final bool play;

  @override
  State<LoopingVideo> createState() => _LoopingVideoState();
}

class _LoopingVideoState extends State<LoopingVideo> {
  VideoPlayerController? _c;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  /// The phone has only a few video decoders. Right after a GIF is picked,
  /// the closing sheet may still hold them all, so a failed start is
  /// retried a few times before giving up.
  Future<void> _start([int attempt = 0]) async {
    VideoPlayerController? c;
    try {
      c = await localVideo(widget.path, widget.mime, mix: true);
      if (!mounted) return c.dispose();
      await c.setLooping(true);
      await c.setVolume(0);
      await c.initialize();
      if (!mounted) return c.dispose();
      _c = c;
      if (widget.play) await c.play();
      setState(() {});
    } catch (_) {
      await c?.dispose();
      if (!mounted) return;
      if (attempt < 4) {
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        if (mounted) return _start(attempt + 1);
        return;
      }
      setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_failed) return const Center(child: Icon(Icons.broken_image));
    if (c == null || !c.value.isInitialized) {
      return const AspectRatio(
        aspectRatio: 1,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c));
  }
}

/// Picture or looping clip for a GIF/sticker file, whatever its real format.
class AnimatedMedia extends StatelessWidget {
  const AnimatedMedia({
    super.key,
    required this.path,
    required this.mime,
    this.fit,
    this.play = true,
  });
  final String path;
  final String mime;
  final BoxFit? fit;
  final bool play;

  @override
  Widget build(BuildContext context) => mime.startsWith('video/')
      ? LoopingVideo(path: path, mime: mime, play: play)
      : localImage(
          path,
          fit: fit ?? BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
        );
}

/// The user's own collection of GIFs and stickers: tap to send, long-press
/// to remove, "+" to add more from the gallery.
class FavoritesSheet extends StatefulWidget {
  const FavoritesSheet({
    super.key,
    required this.state,
    required this.chat,
    this.start = 'library',
  });
  final AppState state;
  final String chat;

  /// Tab to open on: 'library', 'gif' (the user's own) or 'sticker'.
  final String start;

  static Future<void> show(
    BuildContext context,
    AppState state,
    String chat, {
    String start = 'library',
  }) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => FavoritesSheet(state: state, chat: chat, start: start),
  );

  @override
  State<FavoritesSheet> createState() => _FavoritesSheetState();
}

class _FavoritesSheetState extends State<FavoritesSheet> {
  // The first tab is the server's shared collection.
  late String _kind = widget.start;
  bool _busy = false;
  Future<List<GifItem>>? _library;
  final _query = TextEditingController();
  Timer? _debounce;
  Future<List<GifItem>>? _results;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  /// Searches half a second after the user stops typing.
  void _onQuery(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(
        () => _results = text.trim().isEmpty ? null : m.searchGifs(text),
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _library = widget.state.messenger.gifLibrary();
  }

  Future<void> _sendFromLibrary(GifItem item) async {
    setState(() => _busy = true);
    try {
      await m.sendLibraryGif(widget.chat, item);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      _toast('دریافت این گیف انجام نشد.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Search box, then either the search results or the shared collection.
  Widget _libraryTab() {
    final searching = _results != null;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: TextField(
            controller: _query,
            onChanged: _onQuery,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'جستجوی گیف (فارسی یا انگلیسی)',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              suffixIcon: _query.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'پاک کردن',
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () {
                        _query.clear();
                        _onQuery('');
                      },
                    ),
            ),
          ),
        ),
        Expanded(
          child: searching
              ? _grid(
                  _results,
                  empty: 'گیفی با این عبارت پیدا نشد.',
                  retry: () =>
                      setState(() => _results = m.searchGifs(_query.text)),
                )
              : _grid(
                  _library,
                  empty:
                      'مدیر سرور هنوز گیفی به مجموعه اضافه نکرده است. بالا جستجو کنید، یا از برگه «گیف‌های من» گیف‌های خودتان را بفرستید.',
                  retry: () => setState(() => _library = m.gifLibrary()),
                ),
        ),
        // Attribution GIPHY asks for wherever its results are shown.
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            'Powered by GIPHY',
            textDirection: TextDirection.ltr,
            style: TextStyle(fontSize: 10.5, color: Brand.muted(context)),
          ),
        ),
      ],
    );
  }

  Widget _grid(
    Future<List<GifItem>>? future, {
    required String empty,
    required VoidCallback retry,
  }) {
    return FutureBuilder<List<GifItem>>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          final off =
              snap.error is ApiError && (snap.error as ApiError).status == 501;
          return Center(
            child: off
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'جستجوی گیف روی این سرور فعال نیست.',
                      style: TextStyle(color: Brand.muted(context)),
                    ),
                  )
                : TextButton(
                    onPressed: retry,
                    child: const Text('دریافت نشد؛ تلاش دوباره'),
                  ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final items = snap.data!;
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(28),
            child: Text(
              empty,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Brand.muted(context)),
            ),
          );
        }
        return GridView.count(
          crossAxisCount: 3,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            for (final item in items)
              GestureDetector(
                onTap: _busy ? null : () => _sendFromLibrary(item),
                onLongPress: () async {
                  try {
                    final path = await m.gifFile(item);
                    final added = await m.addFavorite(
                      await m.files.read(path),
                      name: path,
                      kind: 'gif',
                      mime: item.mime,
                    );
                    _toast(
                      added
                          ? 'به «گیف‌های من» اضافه شد.'
                          : 'قبلا ذخیره شده بود.',
                    );
                  } catch (_) {
                    _toast('دریافت این گیف انجام نشد.');
                  }
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: ColoredBox(
                    color: Colors.black26,
                    child: _LibraryTile(
                      key: ValueKey(item.id),
                      messenger: m,
                      item: item,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Messenger get m => widget.state.messenger;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _add() async {
    // GIFs saved from other apps are often MP4 clips, so allow both.
    final x = _kind == 'gif'
        ? await ImagePicker().pickMedia()
        : await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return;
    final mime = mimeForName(x.name);
    final ok = _kind == 'gif'
        ? (mime == 'image/gif' ||
              mime == 'image/webp' ||
              mime.startsWith('video/'))
        : mime.startsWith('image/');
    if (!ok) {
      _toast(
        _kind == 'gif'
            ? 'فقط فایل GIF یا کلیپ کوتاه قابل افزودن است.'
            : 'این فایل تصویر نیست.',
      );
      return;
    }
    final bytes = await x.readAsBytes();
    if (bytes.length > MediaTransfer.limits[_kind]!) {
      _toast('حجم این فایل برای ذخیره زیاد است.');
      return;
    }
    setState(() => _busy = true);
    try {
      await m.addFavorite(bytes, name: x.name, kind: _kind, mime: mime);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Adds every GIF in a folder the user picks (for example Downloads).
  Future<void> _importFolder() async {
    final GifFolder? folder;
    try {
      folder = await pickGifFolder(MediaTransfer.limits['gif']!);
    } catch (_) {
      _toast('خواندن پوشه انجام نشد.');
      return;
    }
    if (folder == null) return;
    setState(() => _busy = true);
    var added = 0, repeated = 0;
    try {
      for (final f in folder.files) {
        if (await m.addFavorite(
          f.bytes,
          name: f.name,
          kind: 'gif',
          mime: f.mime,
        )) {
          added++;
        } else {
          repeated++;
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    final notes = [
      fa('$added گیف اضافه شد'),
      if (repeated > 0) fa('$repeated تا قبلا بود'),
      if (folder.tooLarge > 0)
        fa('${folder.tooLarge} تا بیشتر از ۵ مگابایت بود'),
      if (folder.files.isEmpty && folder.tooLarge == 0)
        'در این پوشه گیفی پیدا نشد',
    ];
    _toast(notes.join('، '));
  }

  Widget _tab(String label, String kind) {
    final on = _kind == kind;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _kind = kind),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            gradient: on ? Brand.gradient : null,
            borderRadius: BorderRadius.circular(11),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: on ? Colors.white : Brand.muted(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionTile(IconData icon, String label, VoidCallback run) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: _busy ? null : run,
    child: Container(
      decoration: BoxDecoration(
        color: Brand.page(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary,
          width: 1.4,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final items = _kind == 'library' ? const <Favorite>[] : m.favorites(_kind);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.58,
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Brand.page(context),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  _tab('پیشنهادی', 'library'),
                  _tab('گیف‌های من', 'gif'),
                  _tab('استیکرهای من', 'sticker'),
                ],
              ),
            ),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            if (_kind == 'library') Expanded(child: _libraryTab()),
            if (_kind != 'library')
              Expanded(
                child: GridView.count(
                  crossAxisCount: _kind == 'gif' ? 3 : 4,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  children: [
                    if (_kind == 'gif' && folderImportAvailable)
                      _actionTile(
                        Icons.drive_folder_upload_rounded,
                        'از پوشه',
                        _importFolder,
                      ),
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: _busy ? null : _add,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Brand.page(context),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 1.4,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.add_photo_alternate_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'افزودن',
                              style: TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                    for (final f in items)
                      GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          m.sendFavorite(widget.chat, f);
                        },
                        onLongPress: () async {
                          final remove = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: const Text('حذف از ذخیره‌ها؟'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(d, false),
                                  child: const Text('نه'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(d, true),
                                  child: const Text('حذف'),
                                ),
                              ],
                            ),
                          );
                          if (remove == true) {
                            m.removeFavorite(f.id);
                            if (mounted) setState(() {});
                          }
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: ColoredBox(
                            color: _kind == 'gif'
                                ? Colors.black26
                                : Colors.transparent,
                            child: AnimatedMedia(
                              path: f.path,
                              mime: f.mime,
                              // Clips stay on their first frame in the grid
                              // so a full page of them does not all decode.
                              play: false,
                              fit: _kind == 'gif'
                                  ? BoxFit.cover
                                  : BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (items.isEmpty && _kind != 'library')
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(
                  _kind == 'gif'
                      ? 'هنوز گیفی ذخیره نکرده‌اید. از گالری اضافه کنید، یا روی گیفی که برایتان فرستاده‌اند انگشت نگه دارید و «افزودن به ذخیره‌ها» را بزنید.'
                      : 'هنوز استیکری ذخیره نکرده‌اید. هر تصویر کوچک می‌تواند استیکر شما باشد.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: Brand.muted(context)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One cell of the shared collection: popular GIFs show a still picture,
/// the administrator's own files show themselves.
class _LibraryTile extends StatefulWidget {
  const _LibraryTile({super.key, required this.messenger, required this.item});
  final Messenger messenger;
  final GifItem item;

  @override
  State<_LibraryTile> createState() => _LibraryTileState();
}

class _LibraryTileState extends State<_LibraryTile> {
  late final Future<String> _file = widget.messenger.gifFile(
    widget.item,
    thumb: widget.item.trending,
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _file,
      builder: (context, snap) {
        if (snap.hasError) {
          return const Center(child: Icon(Icons.broken_image));
        }
        if (!snap.hasData) {
          return const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return AnimatedMedia(
          path: snap.data!,
          mime: widget.item.trending ? 'image/gif' : widget.item.mime,
          play: false,
          fit: BoxFit.cover,
        );
      },
    );
  }
}
