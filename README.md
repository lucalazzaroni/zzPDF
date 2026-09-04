# zzPDF

A private, offline, native PDF editor for macOS, built with SwiftUI and PDFKit.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-147EFB)
![Swift](https://img.shields.io/badge/Swift-5.10-F05138)

zzPDF lets you read, organize, fill, annotate, redact, and graphically sign PDF documents without uploading them to an external service. Documents exported by zzPDF can still be digitally signed afterward with services such as Aruba.

The current Apple Silicon build is available at [`dist/zzPDF-macOS-arm64-v0.4.0.zip`](dist/zzPDF-macOS-arm64-v0.4.0.zip).

## Features

- Continuous, single-page, two-page, and two-page continuous layouts.
- Page fitting, actual size, thumbnails, search, zoom, and navigation.
- Visible annotation selection with a clear selection outline; drag to move it or use a corner handle to resize it.
- Highlight, underline, strike-through, notes, and free text.
- Live previews while drawing freehand, shapes, redactions, and signatures.
- Graphic signatures drawn with a mouse or trackpad, or imported from an image file.
- Immediate note editor after placing a note; double-click a note to edit it again.
- Undo and redo with `Command-Z` and `Command-Shift-Z`.
- Direct interaction with PDF form fields.
- Page reordering, rotation, duplication, deletion, cropping, and extraction.
- PDF merging and PDF creation from image files.
- OCR for the current page using Apple Vision.
- Standard save, flattened export, and password protection.

A redaction becomes irreversible only in a copy produced with **Export Flattened**.

## Requirements

- macOS 14 Sonoma or later.
- Apple Silicon for the prebuilt package included in `dist`.
- Xcode 16 or compatible Command Line Tools to rebuild the project.

## Build

Clone the repository and run the build script:

```bash
git clone https://github.com/lucalazzaroni/zzPDF.git
cd zzPDF
./build-app.sh
```

The script creates:

- `outputs/zzPDF.app`
- `outputs/zzPDF-macOS.zip`

The default signature is an ad hoc local signature suitable for development and personal use. To select a specific SDK:

```bash
ZZPDF_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)" ./build-app.sh
```

## Local Installation

Open `outputs/zzPDF-macOS.zip`, then drag `zzPDF.app` to the Applications folder.

## Distribution

Public distribution requires an Apple Developer account, a **Developer ID Application** certificate, Hardened Runtime, and Apple notarization. See [DISTRIBUTION.md](DISTRIBUTION.md) for the complete signing, notarization, Gatekeeper verification, and GitHub release procedure.

## Project Structure

```text
Sources/zzPDF/       application UI and PDF logic
AppResources/        Info.plist and app icon
build-app.sh         release build and app packaging
scripts/notarize.sh  notarization of a Developer ID build
```

## Project Status

zzPDF is an early working release. Structural rewriting of arbitrary existing PDF content while perfectly retaining embedded fonts and layout will require an additional PDF engine in a future version.
