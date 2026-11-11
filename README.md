# Lector 2.0: lector de documentos para Android con voces

App hecha en Flutter que **busca todos tus documentos en el teléfono**, los abre en un lector cómodo y **te los lee en voz alta** con las voces gratuitas de tu teléfono.

## Qué hace

### Biblioteca
- **Busca sola** PDF, EPUB, Word (.docx), TXT y Markdown en:
  - la memoria del teléfono,
  - la tarjeta SD,
  - las carpetas de **WhatsApp y Telegram**.
- **Portadas** en "Continuar leyendo": la primera página del PDF o la portada del EPUB.
- **Filtros** por tipo de archivo y por favoritos.
- **Búsqueda por nombre** sin importar las tildes.
- **Ordenar** por fecha, nombre o tamaño.
- Mantén presionado un documento para **compartirlo, cambiarle el nombre o eliminarlo**.
- **"Abrir con…"**: abre PDF, EPUB, Word o TXT directamente desde WhatsApp, Gmail, Drive o Archivos. También puedes **compartir un texto** con la app para que te lo lea.

### Lectura en voz alta
- Lee **frase por frase** y **resalta la frase y la palabra** que suena.
- **Sigue leyendo con la pantalla apagada**. Desde la notificación puedes pausar o detener.
- Botones de frase anterior y siguiente, **velocidad de 0.5x a 3x** y tono.
- **Temporizador** para dormir (10 a 90 min).
- En los PDF lee página por página y **pasa las páginas solo**.
- Mantén presionado un párrafo y elige **"Escuchar desde aquí"**.
- **Pantalla "Voces de lectura"**, donde puedes:
  - ver todas las voces instaladas (Google, Samsung, SherpaTTS…) con etiquetas como "Sin internet", "Con internet · más natural" y "Alta calidad",
  - escuchar una muestra de cada voz,
  - cambiar el motor de voz.

### Visor PDF
- **Índice** del PDF y **miniaturas** de todas las páginas.
- **Marcadores** por página.
- Búsqueda de texto con resaltado.
- **Modo lectura**: convierte el PDF en texto que se adapta a la pantalla, con tamaño de letra, temas y notas.
- **Pasar páginas de lado** o hacia abajo.
- Modo noche y **pantalla completa** (toca la página).
- Abre PDF **con contraseña**.
- Barra para saltar de página e "ir a página…".

### Lector EPUB / Word / TXT
- **Subrayados de 4 colores y notas** en cada párrafo. Se pueden **compartir todas las notas** de una vez.
- **Marcadores**, índice y búsqueda con resaltado.
- Ajustes de letra, interlineado y letra tipo libro, con temas **Claro, Sepia y Noche**.
- Pantalla completa y opción de mantener la pantalla encendida.
- Recuerda el párrafo exacto donde quedaste.

## Voces gratis que puedes usar

1. **Voces de Google** (vienen en casi todos los Android):
   - Para usarlas sin internet: en la app ve a *Voces de lectura → Descargar voces de Google → Español*.
   - Las que dicen "con internet" suenan más naturales.
2. **Voces de Samsung**: si tienes un Samsung, aparecen solas como otro motor.
3. **SherpaTTS**: voces neuronales Piper, muy naturales, sin internet y de código abierto.
   1. Instálala desde F-Droid (<https://f-droid.org/packages/org.woheller69.ttsengine/>).
   2. Ábrela y descarga una voz en español.
   3. Vuelve a *Voces de lectura* y elige el motor SherpaTTS.

> Si la lectura se corta con la pantalla apagada, ve a Ajustes de Android → Apps → Lector → Batería y elige "Sin restricciones".

## Cómo actualizar el APK (GitHub lo compila gratis)

Si ya tienes el repositorio de la versión 1:

1. En tu repositorio de GitHub, toca **Add file → Upload files**.
2. Sube el nuevo **`lector_docs.zip`** con el mismo nombre, para que reemplace al anterior.
3. Toca **Commit changes**.
4. Espera de 10 a 15 minutos en la pestaña **Actions** hasta que aparezca ✅.
5. Descarga el nuevo **Lector.apk** desde **Releases** e instálalo encima del anterior. Tus favoritos y tu progreso se conservan.

Si es la primera vez, sigue los pasos del archivo `compilar-apk.yml`:

1. Crea un repositorio público.
2. Sube `lector_docs.zip`.
3. Crea `.github/workflows/compilar-apk.yml` con el contenido de ese archivo.

## Primer uso

1. Toca **Dar permiso y buscar** y activa "Acceso a todos los archivos" para Lector.
2. La primera vez que toques 🎧 **Escuchar**, Android preguntará si permites notificaciones. Acepta: así aparecen los controles de la lectura.

## Compilar en tu computador (opcional)

```bash
flutter create --org com.sergio --project-name lector_docs --platforms=android .
flutter pub get
flutter run          # con el celular conectado por USB
flutter build apk    # genera build/app/outputs/flutter-apk/app-release.apk
```

## Estructura del código

```
lib/
  main.dart                       Arranque, archivos recibidos de otras apps
  navigation.dart                 Abrir documentos y mostrar avisos
  models.dart                     Documento, progreso, párrafos
  services/scanner.dart           Busca archivos en el teléfono
  services/library_store.dart     Biblioteca, favoritos, progreso, renombrar/borrar
  services/annotations_store.dart Marcadores, subrayados y notas
  services/reader_settings.dart   Letra, temas, modos de lectura
  services/extractors.dart        EPUB / Word / TXT a texto, portadas EPUB
  services/pdf_text.dart          Texto de los PDF y modo lectura
  services/text_tools.dart        Frases, limpieza de texto de PDF
  services/tts_service.dart       Motores y voces del teléfono
  services/read_aloud.dart        Lectura en voz alta con resaltado
  services/system_bridge.dart     Comunicación con el código Android
  screens/library_screen.dart     Pantalla principal
  screens/pdf_reader_screen.dart  Visor de PDF
  screens/text_reader_screen.dart Lector de EPUB / Word / TXT / modo lectura
  screens/voices_screen.dart      Elegir y probar voces
  widgets/read_aloud_bar.dart     Controles de la lectura en voz alta
android/app/src/main/kotlin/com/sergio/lector_docs/
  MainActivity.kt                 "Abrir con…", ajustes de voz, pantalla encendida
  ReadAloudService.kt             Notificación y lectura con pantalla apagada
```

## Ideas para la siguiente versión

- Voces neuronales Piper integradas dentro de la app, sin instalar otra app.
- Subrayar palabras sueltas dentro del PDF original.
- Reconocimiento de texto (OCR) para leer en voz alta PDF escaneados.
- Cómics (.cbz) y MOBI.
