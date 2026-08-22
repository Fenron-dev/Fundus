import '../model/media_position.dart';

enum ReflowSourceFormat { plainText, markdown, html }

final class ReflowParagraph {
  const ReflowParagraph({
    required this.id,
    required this.text,
    required this.characterStart,
  });

  final String id;
  final String text;
  final int characterStart;

  int get characterEnd => characterStart + text.length;
}

final class ReflowSearchMatch {
  const ReflowSearchMatch({
    required this.paragraphIndex,
    required this.innerOffset,
    required this.matchLength,
    required this.snippet,
  });

  final int paragraphIndex;
  final double innerOffset;
  final int matchLength;
  final String snippet;
}

final class ReflowDocument {
  const ReflowDocument({
    required this.paragraphs,
    required this.totalCharacters,
  });

  factory ReflowDocument.parse(
    String source, {
    required ReflowSourceFormat format,
  }) {
    final normalized = switch (format) {
      ReflowSourceFormat.html => _htmlToText(source),
      ReflowSourceFormat.plainText || ReflowSourceFormat.markdown => source,
    }.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    final blocks = normalized
        .split(RegExp(r'\n\s*\n+'))
        .map((block) => block.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((block) => block.isNotEmpty)
        .toList(growable: false);
    final occurrences = <String, int>{};
    final paragraphs = <ReflowParagraph>[];
    var characterStart = 0;
    for (final block in blocks) {
      final fingerprint = _stableFingerprint(block);
      final occurrence = occurrences.update(
        fingerprint,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      paragraphs.add(
        ReflowParagraph(
          id: 'paragraph-$fingerprint-$occurrence',
          text: block,
          characterStart: characterStart,
        ),
      );
      characterStart += block.length + 2;
    }
    return ReflowDocument(
      paragraphs: paragraphs,
      totalCharacters: characterStart == 0 ? 0 : characterStart - 2,
    );
  }

  final List<ReflowParagraph> paragraphs;
  final int totalCharacters;

  List<ReflowSearchMatch> search(String query, {int limit = 200}) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty || limit <= 0) return const [];
    final matches = <ReflowSearchMatch>[];
    for (
      var paragraphIndex = 0;
      paragraphIndex < paragraphs.length && matches.length < limit;
      paragraphIndex++
    ) {
      final paragraph = paragraphs[paragraphIndex];
      final haystack = paragraph.text.toLowerCase();
      var start = 0;
      while (start < haystack.length && matches.length < limit) {
        final index = haystack.indexOf(needle, start);
        if (index < 0) break;
        final snippetStart = (index - 54).clamp(0, paragraph.text.length);
        final snippetEnd = (index + needle.length + 70).clamp(
          0,
          paragraph.text.length,
        );
        final prefix = snippetStart > 0 ? '…' : '';
        final suffix = snippetEnd < paragraph.text.length ? '…' : '';
        matches.add(
          ReflowSearchMatch(
            paragraphIndex: paragraphIndex,
            innerOffset: paragraph.text.isEmpty
                ? 0
                : index / paragraph.text.length,
            matchLength: needle.length,
            snippet:
                '$prefix${paragraph.text.substring(snippetStart, snippetEnd).replaceAll(RegExp(r'\s+'), ' ')}$suffix',
          ),
        );
        start = index + needle.length;
      }
    }
    return List.unmodifiable(matches);
  }

  ({int paragraphIndex, double innerOffset}) resolve(MediaPosition? position) {
    if (paragraphs.isEmpty) return (paragraphIndex: 0, innerOffset: 0);
    final elementId = position?.elementId;
    if (elementId != null) {
      final index = paragraphs.indexWhere((item) => item.id == elementId);
      if (index >= 0) {
        return (
          paragraphIndex: index,
          innerOffset: (position?.scrollOffset ?? 0).clamp(0, 1),
        );
      }
    }
    final character = (position?.numericValue ?? 0).clamp(0, totalCharacters);
    var index = paragraphs.length - 1;
    for (var candidate = 0; candidate < paragraphs.length; candidate++) {
      if (character <= paragraphs[candidate].characterEnd) {
        index = candidate;
        break;
      }
    }
    final paragraph = paragraphs[index];
    final innerOffset = paragraph.text.isEmpty
        ? 0.0
        : ((character - paragraph.characterStart) / paragraph.text.length)
              .clamp(0, 1)
              .toDouble();
    return (paragraphIndex: index, innerOffset: innerOffset);
  }

  MediaPosition positionFor({
    required int paragraphIndex,
    required double innerOffset,
    String? fileId,
    String? chapterId,
    String? key,
  }) {
    if (paragraphs.isEmpty) {
      return MediaPosition(
        kind: MediaPositionKind.epubCfi,
        numericValue: 0,
        total: 0,
        fileId: fileId,
        chapterId: chapterId,
        key: key,
        label: 'Dokumentanfang',
      );
    }
    final index = paragraphIndex.clamp(0, paragraphs.length - 1);
    final paragraph = paragraphs[index];
    final offset = innerOffset.clamp(0, 1).toDouble();
    final character = paragraph.characterStart + paragraph.text.length * offset;
    final percent = totalCharacters <= 0
        ? 0
        : (character / totalCharacters * 100).clamp(0, 100).round();
    return MediaPosition(
      kind: MediaPositionKind.epubCfi,
      numericValue: character,
      total: totalCharacters.toDouble(),
      fileId: fileId,
      chapterId: chapterId,
      elementId: paragraph.id,
      scrollOffset: offset,
      key: key,
      label: '$percent %',
    );
  }
}

String _htmlToText(String source) {
  var text = source
      .replaceAll(
        RegExp(
          r'<(script|style|svg|head)\b[^>]*>[\s\S]*?</\1\s*>',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(
          r'</?(p|div|section|article|main|aside|h[1-6]|li|blockquote|tr|pre)\b[^>]*>',
          caseSensitive: false,
        ),
        '\n\n',
      )
      .replaceAll(RegExp(r'<[^>]+>'), '');
  text = text.replaceAllMapped(RegExp(r'&#(x?[0-9a-fA-F]+);'), (match) {
    final raw = match.group(1)!;
    final hexadecimal = raw.startsWith('x') || raw.startsWith('X');
    final value = int.tryParse(
      hexadecimal ? raw.substring(1) : raw,
      radix: hexadecimal ? 16 : 10,
    );
    return value == null || value > 0x10ffff
        ? match.group(0)!
        : String.fromCharCode(value);
  });
  const entities = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&apos;': "'",
    '&#39;': "'",
    '&ndash;': '–',
    '&mdash;': '—',
    '&hellip;': '…',
  };
  for (final entry in entities.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  return text;
}

String _stableFingerprint(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.trim().toLowerCase().codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
