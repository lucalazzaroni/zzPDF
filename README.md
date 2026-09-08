# zzPDF

A private, offline, native PDF editor for macOS, built with SwiftUI and PDFKit.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-147EFB)
![Swift](https://img.shields.io/badge/Swift-5.10-F05138)

zzPDF lets you read, organize, fill, annotate, redact, and graphically sign PDF documents without uploading them to an external service. Documents exported by zzPDF can still be digitally signed afterward with services such as Aruba.

The current Apple Silicon build is available at [`dist/zzPDF-macOS-arm64-v0.5.8.zip`](dist/zzPDF-macOS-arm64-v0.5.8.zip).

## Features

- Continuous, single-page, two-page, and two-page continuous layouts.
- Page fitting, actual size, thumbnails, search with `Command-F`, zoom, and navigation.
- Visible annotation selection with a clear selection outline; corner handles remain usable immediately after drawing and scale freehand ink instead of clipping it.
- A single text-markup tool with interactive drag-to-highlight, underline, and strike-through submodes and dedicated cursors.
- A compact Shapes tool groups rectangles and ellipses, with accurate live stroke previews, optional fills, and editable stroke width and fill after insertion.
- Added free text shows a temporary “Text” placeholder on the page, then opens a focused blank editor; it can be edited again by double-clicking it in Select mode.
- Selected-text actions appear only when text is actually selected in Select mode.
- Live previews while drawing freehand, shapes, redactions, and signatures.
- Graphic signatures drawn with a mouse or trackpad, or imported from an image file.
- Immediate note editor after placing a note; `Command-Return` saves and keeps the Note tool active, while `Escape` removes a new unsaved note.
- Fast in-place undo and redo with `Command-Z` and `Command-Y`, without reloading the document or losing the current page.
- `Escape` returns any annotation tool to Select mode.
- A dedicated Fill Forms mode with persistent, clickable PDFKit controls for text fields, checkboxes, radio buttons, and choices; Select mode stays visually clean.
- Black as the default color for text, freehand ink, shapes, and graphic signatures.
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
Tests/InkResizeSmoke/ standalone Ink path-resize regression check
Tests/FormOverlaySmoke/ standalone interactive form-overlay regression check
```

## Project Status

zzPDF is an early working release. Structural rewriting of arbitrary existing PDF content while perfectly retaining embedded fonts and layout will require an additional PDF engine in a future version.
