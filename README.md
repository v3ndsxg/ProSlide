# ProSlide
A Mac app that gets things into ProPresenter quickly. It turns PDF and PowerPoint files into slides, downloads videos and audio from YouTube and social media, and formats song lyrics into presentations. Everything it makes lands in one bin, ready to drag into ProPresenter.

## Requirements
- A Mac with Apple Silicon (M1 or newer), running macOS 13 or later
- Xcode 15 or later, or the Swift Command Line Tools (`xcode-select --install`), to build the app
- [LibreOffice](https://www.libreoffice.org), only if you convert PowerPoint files
- ProPresenter 7 or later

To install:

```
git clone https://github.com/v3ndsxg/ProSlide.git
cd ProSlide
./Scripts/make-app-bundle.sh --install
open /Applications/ProSlide.app
```

The first time you open it, macOS may block it. Right-click the app and choose **Open**.

## Using ProSlide
1. Drag your PDF or PowerPoint files onto the window and press **Convert**.
2. Each file appears as a tile in the bin on the right.
3. Drag a tile into ProPresenter. It arrives as a complete presentation, with one slide per page.

To drag just the slide images instead, switch the bin to **JPEG Files**. Right-click a tile to show it in Finder or save a copy.

## Features
### Converter
Turns PDFs and PowerPoint files (`.pptx` and `.ppt`) into slides in HD, Full HD or 4K. Add as many files as you like; they convert one at a time, and the bin remembers them between launches.

### Downloader
Paste links from YouTube or most social media sites, choose **MP4 Video** (up to 4K) or **MP3 Audio**, and press **Download**. Each download appears in the bin, ready to drag into ProPresenter. Only download videos you own or have permission to use.

### Lyrics Formatter
Paste a song's lyrics with its section labels (Verse, Chorus, Bridge and so on), type the title, and press **Create Presentation**. You'll see a preview of the slides as you type, and can choose 2, 4 or all lines per slide. Each section becomes its own color-coded group, and ProSlide checks your ProPresenter library so you don't add a song twice.
