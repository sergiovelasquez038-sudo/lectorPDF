/// Herramientas de texto sin dependencias de Flutter (se pueden probar solas).
library;

/// Un trozo de texto: desde [start] (incluido) hasta [end] (excluido).
class TextSegment {
  const TextSegment(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start;

  @override
  String toString() => 'TextSegment($start, $end)';
}

final _letterRe = RegExp(r'\p{L}', unicode: true);
final _wordCharRe = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _digitRe = RegExp(r'[0-9]');

const _abbreviations = {
  'sr', 'sra', 'srta', 'srs', 'dr', 'dra', 'drs', 'ud', 'uds', 'vd', 'vds',
  'lic', 'ing', 'arq', 'prof', 'profa', 'etc', 'pág', 'pag', 'págs', 'núm',
  'num', 'no', 'nro', 'art', 'cap', 'fig', 'vol', 'ed', 'av', 'avda', 'ej',
  'p', 'pp', 'cía', 'ltda', 'st', 'mr', 'mrs', 'ms', 'vs', 'aprox', 'tel',
  'dto', 'dpto', 'gral', 'cnel', 'sto', 'sta', 'jr', 'inc', 'co', 'approx',
};

const _closers = '.!?…»"”’\')]';

bool _isSpace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 ||
    c == 0x2009 || c == 0x200A || c == 0x202F || c == 0x3000;

bool isLetter(String ch) => _letterRe.hasMatch(ch);

bool isLowerLetter(String ch) =>
    isLetter(ch) && ch.toLowerCase() == ch && ch.toUpperCase() != ch;

bool _isAbbreviation(String text, int segmentStart, int dot) {
  var k = dot;
  while (k > segmentStart && isLetter(text[k - 1])) {
    k--;
  }
  final word = text.substring(k, dot);
  if (word.isEmpty) {
    // "1." o "12." al comienzo de un renglón: es una lista, no un final.
    var d = dot;
    while (d > segmentStart && _digitRe.hasMatch(text[d - 1])) {
      d--;
    }
    final digits = dot - d;
    return digits > 0 && digits <= 3 && text.substring(segmentStart, d).trim().isEmpty;
  }
  // Iniciales como "J. R. R. Tolkien"
  if (word.length == 1 && word.toUpperCase() == word) return true;
  return _abbreviations.contains(word.toLowerCase());
}

void _splitLong(String text, int s, int e, int max, List<TextSegment> out) {
  while (e - s > max) {
    var cut = -1;
    for (var k = s + max; k > s + max ~/ 2; k--) {
      final ch = text[k];
      if (ch == ',' || ch == ':' || ch == '—' || ch == ')' || ch == '–') {
        cut = k + 1;
        break;
      }
    }
    if (cut < 0) {
      for (var k = s + max; k > s; k--) {
        if (_isSpace(text.codeUnitAt(k))) {
          cut = k;
          break;
        }
      }
    }
    if (cut <= s) cut = s + max;
    var end = cut;
    while (end > s && _isSpace(text.codeUnitAt(end - 1))) {
      end--;
    }
    if (end > s) out.add(TextSegment(s, end));
    s = cut;
    while (s < e && _isSpace(text.codeUnitAt(s))) {
      s++;
    }
  }
  if (e > s) out.add(TextSegment(s, e));
}

/// Divide un párrafo en frases para leerlas en voz alta una por una.
/// Las frases muy largas se cortan en comas o espacios.
List<TextSegment> splitSentences(String text, {int maxLength = 350}) {
  final out = <TextSegment>[];
  final n = text.length;

  void emit(int s, int e) {
    while (s < e && _isSpace(text.codeUnitAt(s))) {
      s++;
    }
    while (e > s && _isSpace(text.codeUnitAt(e - 1))) {
      e--;
    }
    if (e <= s) return;
    if (!_wordCharRe.hasMatch(text.substring(s, e))) return;
    if (e - s > maxLength) {
      _splitLong(text, s, e, maxLength, out);
    } else {
      out.add(TextSegment(s, e));
    }
  }

  var start = 0;
  var i = 0;
  while (i < n) {
    final c = text[i];
    if (c == '\n') {
      emit(start, i);
      start = i + 1;
      i++;
      continue;
    }
    if (c == '.' || c == '!' || c == '?' || c == '…') {
      var j = i + 1;
      while (j < n && _closers.contains(text[j])) {
        j++;
      }
      final atEnd = j >= n;
      if (atEnd || _isSpace(text.codeUnitAt(j))) {
        if (c == '.' && j == i + 1 && _isAbbreviation(text, start, i)) {
          i = j;
          continue;
        }
        emit(start, j);
        start = j;
      }
      i = j;
      continue;
    }
    i++;
  }
  emit(start, n);
  return out;
}

/// Cambia símbolos que la voz leería en voz alta ("asterisco", "viñeta")
/// por espacios. Conserva la longitud para que el resaltado coincida.
String speakableText(String s) {
  const symbols = '•*_#|~^\t\n\r▪●◦■□►▶';
  final units = s.codeUnits.toList();
  for (var i = 0; i < units.length; i++) {
    if (symbols.contains(String.fromCharCode(units[i]))) units[i] = 0x20;
  }
  return String.fromCharCodes(units);
}

// ===================== Texto de PDF → párrafos =====================

final _pageNumberLine = RegExp(
    r'^(?:p[áa]g(?:ina)?\.?\s*|page\s*)?\d{1,4}(?:\s*(?:de|/|of)\s*\d{1,4})?$',
    caseSensitive: false);
final _endsSentence = RegExp(r'[.!?:»"”…]$');
final _listItemStart = RegExp(r'^(?:[•\-–▪●◦]|\d{1,3}[.)])\s');
final _startsUpper = RegExp(r'^[\p{Lu}\d¿¡"«]', unicode: true);
final _softEnd = RegExp(r'[,;\-–]$');

/// Convierte el texto de una página de PDF (renglones cortados)
/// en párrafos corridos, separados por saltos de línea.
String reflowPdfPage(String raw) {
  final lines = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((l) => l.trim())
      .toList();

  // Números de página al principio o al final de la hoja
  while (lines.isNotEmpty &&
      (lines.first.isEmpty || _pageNumberLine.hasMatch(lines.first))) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty &&
      (lines.last.isEmpty || _pageNumberLine.hasMatch(lines.last))) {
    lines.removeLast();
  }
  if (lines.isEmpty) return '';

  final lengths = lines.where((l) => l.isNotEmpty).map((l) => l.length).toList()
    ..sort();
  final typical = lengths.isEmpty
      ? 0
      : lengths[((lengths.length - 1) * 0.8).floor()];

  final paragraphs = <String>[];
  final buf = StringBuffer();
  var prev = '';

  void flush() {
    final t = buf.toString().trim();
    if (t.isNotEmpty) paragraphs.add(t);
    buf.clear();
    prev = '';
  }

  for (final line in lines) {
    if (line.isEmpty) {
      flush();
      continue;
    }
    if (buf.isNotEmpty) {
      final shortPrev = typical > 0 && prev.length < typical * 0.7;
      final veryShort = typical > 0 && prev.length < typical * 0.6;
      // Un renglón muy corto seguido de otro en mayúscula suele ser un título.
      if ((_endsSentence.hasMatch(prev) && shortPrev) ||
          _listItemStart.hasMatch(line) ||
          (veryShort && _startsUpper.hasMatch(line) && !_softEnd.hasMatch(prev))) {
        flush();
      }
    }
    if (buf.isEmpty) {
      buf.write(line);
    } else if (prev.length > 1 &&
        prev.endsWith('-') &&
        isLetter(prev[prev.length - 2]) &&
        isLowerLetter(line[0])) {
      // Palabra cortada con guion: "lec-" + "tura" = "lectura"
      final s = buf.toString();
      buf
        ..clear()
        ..write(s.substring(0, s.length - 1))
        ..write(line);
    } else {
      buf
        ..write(' ')
        ..write(line);
    }
    prev = line;
  }
  flush();
  return paragraphs.join('\n');
}

/// true si el párrafo parece terminar una idea (para unir párrafos
/// que quedaron partidos entre dos páginas).
bool endsSentence(String text) => _endsSentence.hasMatch(text.trimRight());

/// Primeras palabras de un texto, para mostrar en listas.
String excerpt(String text, [int max = 90]) {
  final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.length <= max) return t;
  final cut = t.lastIndexOf(' ', max);
  return '${t.substring(0, cut > max ~/ 2 ? cut : max)}…';
}
