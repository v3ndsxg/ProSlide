# File Converter — Project Handoff

## Goal

Create a lightweight native macOS application that converts PDF pages and PowerPoint (`.pptx`) slides into numbered JPEGs for dependable ProPresenter import.

## Current implementation

The SwiftUI macOS project has been created in this folder.

- `Package.swift` — open this on a Mac in Xcode.
- `Sources/FileConverter/` — application source code.
- `README.md` — requirements and run instructions.
- `Plan.md` — original product plan.

### Included features

- Drag-and-drop or file-picker input for PDF and PPTX files.
- JPEG quality control and 2x/HD/Full HD/4K width presets.
- Downloads as the default export location, with a selectable destination.
- Progress and user-facing conversion errors.
- Numbered JPEG export into a new, collision-safe folder for every job.
- An export shelf with thumbnail drag-and-drop support for ProPresenter, plus an Open Folder action.

### Conversion pipeline

```text
PDF  → PDFKit/Core Graphics → JPEGs
PPTX → LibreOffice headless → temporary PDF → PDFKit/Core Graphics → JPEGs
```

Rust is installed as a future option, but no Rust module is part of this MVP. Using Swift for the app shell and Apple document APIs keeps the first release lightweight; Rust would not improve PowerPoint rendering, which is performed by LibreOffice.

## Linux test results — successful

Date: 2026-09-20

- LibreOffice 26.8.0.3 is installed.
- Rust 1.98.1 and Cargo 1.98.1 are installed.
- A disposable presentation fixture was created and converted to PPTX.
- The exact renderer path used by the app was validated:

```text
fixture.pptx → soffice --headless --convert-to pdf → fixture.pdf
```

- The resulting PDF was produced successfully (12,910 bytes).

## What still requires macOS

Linux cannot build or run the Apple-framework portion of this project. Test the following on the Mac that has LibreOffice and ProPresenter installed:

1. Install Xcode from the Mac App Store and launch it once.
2. Copy this complete `FileConverter` folder to the Mac.
3. Open `Package.swift` in Xcode.
4. Select the `FileConverter` scheme and press Run.
5. Convert a representative PDF and PPTX.
6. Confirm the selected output folder contains correctly numbered JPEGs.
7. Drag JPEG thumbnails from the export shelf, or the Finder output folder, into ProPresenter.
8. Compare the converted images against the original slides, especially fonts, images, gradients, and uncommon PowerPoint effects.

## Known limitation

LibreOffice can substitute missing fonts or render PowerPoint-only effects differently. PDF input is generally the most predictable route. A later version could optionally use Microsoft PowerPoint automation when Office is installed and exact Office rendering is necessary.
