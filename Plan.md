MacOS File Converter Plan:

1. Core Application
  - Drag and drop a simple .pptx or .pdf file
  - Selection box for quality and resolution output
  - Convert each slide/pdf page into a numbered JPEG file
  - Export to a chosen folder (default should be the Downloads Folder)
  - A dock inside of the application that directly opens the exported folder with the JPEG files and can drag and drop those files directly into ProPresenter

2. Technical Details
  - Build it using lightweight Rust + SwiftUI MacOS application
  - Render PDFs with Apple's PDFKit
  - PowerPoint files needs to use LibreOffice Headless mode to convert the whole .pptx to .pdf, then render the pdf files into JPEG
  - Package the converter dependency or check to see if LibreOffice is installed on the machine

3. Scope of The Project
  - Drag-and-drop capabilities
  - JPEG quality and resolution options
  - Transparent progress bars and errors
  - Preserve slide appearance as rendered images, rather than attempting to preserve editable objects.

4. Importing limitations
  - .pptx files cannot be rendered alone. Make sure that PowerPoint/LibreOffice is installed on the system. LibreOffice will be the main focus though as it is free and open source.
  - Converting them effectively into images is sometimes difficult depending on what was put into the PowerPoint file. Less of an issue when submitted as a PDF.

5. Other Features
  - Other image file type support
  - PowerPoint-installed rendering option for highest Office fidelity
  - Presets for 16:9 and 16:10 screens
