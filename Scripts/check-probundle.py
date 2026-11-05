#!/usr/bin/env python3
"""Checks .probundle files the way ProPresenter will read them.

    python3 -I Scripts/check-probundle.py Deck.probundle [More.probundle ...]
    python3 -I Scripts/check-probundle.py path/to/folder   # every bundle under it

CI runs this on the bundles the tests build from the fixtures. It also works on
a bundle copied off a Mac, and it needs nothing beyond the Python standard
library, so it runs on Linux too.

It is written separately from ZipWriter, ProPresenterDocument and the tests'
own readers, and shares no code with them, so it cannot repeat their mistakes.
It checks:

- The zip: CRCs, names that agree between the directory and the local headers,
  every entry stored and flagged UTF-8, readable permissions, and no absolute
  or `..` paths.
- The layout: one `<Name>.pro` at the root, and only JPEGs under
  `Media/Assets/`.
- The images: each one is a complete JPEG with a real size.
- A lyrics bundle (a `.pro` and nothing else, as the Lyrics Formatter writes):
  each cue is one text slide whose RTF parses, and whose text attributes cover
  exactly its text; every cue is in one group, and the arrangement names only
  groups that exist.
- The `.pro`: it decodes, it is named after its file, and every UUID in it is
  well formed and unique. The cue group lists the cues in their own order.
  Each cue holds a slide action and a foreground media action, and the media
  action names its image twice, the same way both times, under the bundle's
  root. Each named image is in the bundle exactly once, and nothing in the
  bundle goes unnamed. Each slide's canvas and image size match the JPEG's
  pixels. No path from the machine that built the bundle leaks into it.

Field numbers follow ProPresenterDocument.swift, which follows the
community-documented `rv.data` schema. Prints one line per bundle, then any
problems, and exits 1 if there were any.
"""

import re
import struct
import sys
import zipfile
from pathlib import Path, PurePosixPath

MEDIA_FOLDER = "Media/Assets"
UTF8_FLAG = 1 << 11
ROOT_SHOW = 10
ACTION_MEDIA = 2
ACTION_PRESENTATION_SLIDE = 11
LAYER_FOREGROUND = 1
UUID = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")

# Paths that only exist on the machine that built a bundle. Any of these in the
# manifest would point ProPresenter at a file on someone else's Mac.
MACHINE_PATHS = (b"file://", b"/Users/", b"/private/", b"/var/folders/", b"/tmp/", b"/Library/")


class Malformed(Exception):
    pass


# MARK: - Protobuf wire format


def decode(buffer):
    """Every field in `buffer`, in order, as (number, wire type, value). Nested
    messages come back as bytes, for `decode` to be called on again."""
    fields = []
    position = 0

    def varint():
        nonlocal position
        result = shift = 0
        while True:
            if position >= len(buffer):
                raise Malformed("a varint runs off the end of the message")
            byte = buffer[position]
            position += 1
            result |= (byte & 0x7F) << shift
            if not byte & 0x80:
                return result
            shift += 7
            if shift > 63:
                raise Malformed("a varint is longer than ten bytes")

    def take(count):
        nonlocal position
        if position + count > len(buffer):
            raise Malformed("a field runs off the end of the message")
        value = bytes(buffer[position:position + count])
        position += count
        return value

    while position < len(buffer):
        key = varint()
        number, wire = key >> 3, key & 7
        if number == 0:
            raise Malformed("a field is numbered 0")
        if wire == 0:
            value = varint()
        elif wire == 1:
            value = take(8)
        elif wire == 2:
            value = take(varint())
        elif wire == 5:
            value = take(4)
        else:
            raise Malformed(f"field {number} has wire type {wire}, which proto3 does not use")
        fields.append((number, wire, value))
    return fields


class Message:
    """A decoded message, read by field number. proto3 leaves zero values off
    the wire, so a missing scalar reads as zero."""

    def __init__(self, buffer):
        self.fields = decode(buffer)

    def all(self, number):
        return [value for n, _, value in self.fields if n == number]

    def messages(self, number):
        return [Message(value) for value in self.all(number)]

    def message(self, *path):
        current = self
        for number in path:
            found = current.all(number)
            if not found:
                return None
            current = Message(found[0])
        return current

    def uint(self, number):
        found = self.all(number)
        return found[0] if found else 0

    def string(self, number):
        found = self.all(number)
        return found[0].decode("utf-8") if found else ""

    def double(self, number):
        found = self.all(number)
        return struct.unpack("<d", found[0])[0] if found else 0.0


# MARK: - JPEG


def jpeg_size(data):
    """(width, height) from a JPEG's frame header, or raises Malformed."""
    if data[:2] != b"\xff\xd8":
        raise Malformed("does not start with a JPEG marker")
    if data[-2:] != b"\xff\xd9":
        raise Malformed("is cut short: no end-of-image marker")
    position = 2
    while position + 4 <= len(data):
        if data[position] != 0xFF:
            raise Malformed(f"has a broken marker at byte {position}")
        marker = data[position + 1]
        if marker == 0xFF:
            position += 1
            continue
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:
            position += 2
            continue
        length = int.from_bytes(data[position + 2:position + 4], "big")
        # Every SOFn frame header except DHT (C4), JPG (C8) and DAC (CC).
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            height = int.from_bytes(data[position + 5:position + 7], "big")
            width = int.from_bytes(data[position + 7:position + 9], "big")
            if width == 0 or height == 0:
                raise Malformed(f"declares a {width}x{height} frame")
            return width, height
        if marker == 0xDA:
            break
        position += 2 + length
    raise Malformed("has no frame header before its image data")


# MARK: - Checks


def check(path):
    """The problems with the bundle at `path`, and a one-line summary."""
    problems = []
    try:
        archive = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError) as error:
        return [f"not a readable zip: {error}"], "unreadable"

    with archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]

        # The zip itself.
        try:
            broken = archive.testzip()
            if broken:
                problems.append(f"{broken}: CRC does not match its contents")
        except (zipfile.BadZipFile, OSError) as error:
            problems.append(f"the archive is damaged: {error}")
        if len(set(names)) != len(names):
            problems.append("an entry name appears more than once")
        for info in infos:
            name = info.filename
            parts = PurePosixPath(name).parts
            if name.startswith("/") or "\\" in name or ".." in parts:
                problems.append(f"{name}: unsafe path")
            if info.is_dir():
                problems.append(f"{name}: a directory entry; the bundle should hold only files")
            if info.compress_type != zipfile.ZIP_STORED:
                problems.append(f"{name}: compressed (method {info.compress_type}); bundles store their entries")
            if not info.flag_bits & UTF8_FLAG:
                problems.append(f"{name}: name not flagged as UTF-8")
            mode = info.external_attr >> 16
            if info.create_system == 3 and mode and not mode & 0o444:
                problems.append(f"{name}: extracts unreadable (mode {oct(mode)})")

        # The layout.
        manifests = [n for n in names if "/" not in n and n.endswith(".pro")]
        if len(manifests) != 1:
            problems.append(f"expected one .pro at the root, found {len(manifests) or 'none'}: {manifests}")
            return problems, f"{len(names)} entries"
        manifest_name = manifests[0]
        images = {}
        for name in names:
            if name == manifest_name:
                continue
            folder = str(PurePosixPath(name).parent)
            if folder != MEDIA_FOLDER:
                problems.append(f"{name}: outside {MEDIA_FOLDER}/")
            elif PurePosixPath(name).suffix.lower() not in (".jpg", ".jpeg"):
                problems.append(f"{name}: not a JPEG")
            else:
                images[name] = None
        # A bundle with nothing but its manifest is a lyrics bundle: text slides
        # have no media.
        lyrics = len(names) == 1
        if not images and not lyrics:
            problems.append(f"no images under {MEDIA_FOLDER}/")

        # The images.
        for name in images:
            try:
                images[name] = jpeg_size(archive.read(name))
            except Malformed as error:
                problems.append(f"{name}: {error}")
            except (zipfile.BadZipFile, OSError) as error:
                problems.append(f"{name}: unreadable: {error}")

        # The manifest.
        try:
            raw = archive.read(manifest_name)
        except (zipfile.BadZipFile, OSError) as error:
            problems.append(f"{manifest_name}: unreadable: {error}")
            return problems, f"{len(images)} images"
        try:
            if lyrics:
                slides = check_lyrics_manifest(raw, manifest_name, problems)
            else:
                slides = check_manifest(raw, manifest_name, images, problems)
        except (Malformed, UnicodeDecodeError, struct.error) as error:
            problems.append(f"{manifest_name}: does not decode: {error}")
            slides = 0

    stem = PurePosixPath(manifest_name).stem
    if Path(path).stem != stem:
        problems.append(f"the file is named {Path(path).name!r} but holds a presentation named {stem!r}")
    return problems, f"{slides} slides, {len(images)} images, {Path(path).stat().st_size:,} bytes"


def check_manifest(raw, manifest_name, images, problems):
    """Checks the `rv.data.Presentation` in `raw` and returns its cue count."""
    for leak in MACHINE_PATHS:
        if leak in raw:
            problems.append(f"{manifest_name}: contains {leak.decode()!r}, a path on the machine that built it")

    document = Message(raw)
    uuids = []

    def uuid(message, where):
        value = message.string(1) if message else ""
        if not UUID.match(value):
            problems.append(f"{where}: {value!r} is not an uppercase UUID")
        uuids.append(value)
        return value

    stem = PurePosixPath(manifest_name).stem
    uuid(document.message(2), "presentation")
    if document.string(3) != stem:
        problems.append(f"presentation is named {document.string(3)!r} but its file is {manifest_name!r}")

    cues = document.messages(13)
    if not cues:
        problems.append("presentation has no cues")
    cue_uuids = [uuid(cue.message(1), f"cue {index + 1}") for index, cue in enumerate(cues)]

    groups = document.messages(12)
    if len(groups) != 1:
        problems.append(f"expected one cue group, found {len(groups)}")
    for group in groups:
        uuid(group.message(1, 1), "cue group")
        listed = [identifier.string(1) for identifier in group.messages(2)]
        if listed != cue_uuids:
            problems.append("the cue group does not list the cues in order, so the deck has no readable slide order")

    referenced = {}
    for index, cue in enumerate(cues, start=1):
        where = f"cue {index} ({cue.string(2)!r})"
        if not cue.uint(12):
            problems.append(f"{where}: disabled")
        actions = cue.messages(10)
        kinds = [action.uint(9) for action in actions]
        if kinds != [ACTION_PRESENTATION_SLIDE, ACTION_MEDIA]:
            problems.append(f"{where}: actions are {kinds}, expected a slide then media {[ACTION_PRESENTATION_SLIDE, ACTION_MEDIA]}")
            continue
        slide, media = actions
        for action, kind in ((slide, "slide"), (media, "media")):
            uuid(action.message(1), f"{where} {kind} action")
            if not action.uint(6):
                problems.append(f"{where}: {kind} action disabled")

        base = slide.message(23, 2, 1)
        canvas = base.message(6) if base else None
        uuid(base.message(7) if base else None, f"{where} canvas")

        if media.message(20) is None or media.message(20).uint(10) != LAYER_FOREGROUND:
            problems.append(f"{where}: media is not on the foreground layer")
        element = media.message(20, 5)
        if element is None:
            problems.append(f"{where}: media action holds no media")
            continue
        uuid(element.message(1), f"{where} media")

        paths = []
        for label, url in (("url", element.message(2, 4)), ("image file url", element.message(5, 2, 1, 4))):
            if url is None:
                problems.append(f"{where}: no {label}")
                continue
            if url.uint(1) != ROOT_SHOW:
                problems.append(f"{where}: {label} has root {url.uint(1)}, not the bundle's own ({ROOT_SHOW})")
            paths.append(url.string(2))
        if len(set(paths)) > 1:
            problems.append(f"{where}: the two media urls disagree: {paths}")
        if not paths:
            continue
        path = paths[0]
        referenced[path] = referenced.get(path, 0) + 1
        if path not in images:
            problems.append(f"{where}: names {path!r}, which is not in the bundle")
            continue

        extension = element.message(3).string(5) if element.message(3) else ""
        if extension != PurePosixPath(path).suffix.lstrip("."):
            problems.append(f"{where}: metadata says {extension!r} for {path!r}")

        pixels = images[path]
        if pixels is None:
            continue
        natural = element.message(5, 1, 5)
        for label, size in (("canvas", canvas), ("image size", natural)):
            declared = (size.double(1), size.double(2)) if size else (0.0, 0.0)
            if declared != (float(pixels[0]), float(pixels[1])):
                problems.append(
                    f"{where}: {label} is {declared[0]:g}x{declared[1]:g}, "
                    f"but {path} is {pixels[0]}x{pixels[1]}"
                )

    for path, count in referenced.items():
        if count > 1:
            problems.append(f"{path}: named by {count} cues")
    for path in images:
        if path not in referenced:
            problems.append(f"{path}: in the bundle but no cue shows it")
    seen = set()
    for value in uuids:
        if value and value in seen:
            problems.append(f"UUID {value} is used more than once")
        seen.add(value)
    return len(cues)


# MARK: - Lyrics bundles


def rtf_text(rtf):
    """The text an RTF document shows, as the Lyrics Formatter writes it: one
    paragraph at the top level, line breaks as a backslash before a newline,
    and anything beyond ASCII as \\uN. Text inside nested groups (the font and
    colour tables) is not shown, so it is skipped."""
    if not rtf.startswith("{\\rtf1"):
        raise Malformed("the text is not RTF")
    text = []
    depth = 0
    position = 0
    while position < len(rtf):
        character = rtf[position]
        if character == "{":
            depth += 1
            position += 1
        elif character == "}":
            depth -= 1
            position += 1
            if depth < 0:
                raise Malformed("the RTF closes more groups than it opens")
        elif character == "\\":
            following = rtf[position + 1:position + 2]
            if following in ("\\", "{", "}"):
                if depth == 1:
                    text.append(following)
                position += 2
            elif following == "\n":
                if depth == 1:
                    text.append("\n")
                position += 2
            else:
                match = re.match(r"\\(\*|[a-zA-Z]+)(-?\d+)? ?", rtf[position:])
                if not match:
                    raise Malformed(f"unreadable RTF control at {position}")
                word, number = match.group(1), match.group(2)
                if word == "u" and number is not None and depth == 1:
                    text.append(chr(int(number) % 65536))
                position += match.end()
        elif character in "\r\n":
            position += 1
        else:
            if depth == 1:
                text.append(character)
            position += 1
    if depth != 0:
        raise Malformed("the RTF leaves a group open")
    return "".join(text)


def check_lyrics_manifest(raw, manifest_name, problems):
    """Checks a lyrics bundle's `rv.data.Presentation` and returns its cue count."""
    for leak in MACHINE_PATHS:
        if leak in raw:
            problems.append(f"{manifest_name}: contains {leak.decode()!r}, a path on the machine that built it")

    document = Message(raw)
    uuids = []

    def uuid(message, where, unique=True):
        value = message.string(1) if message else ""
        if not UUID.match(value):
            problems.append(f"{where}: {value!r} is not an uppercase UUID")
        if unique:
            uuids.append(value)
        return value

    stem = PurePosixPath(manifest_name).stem
    uuid(document.message(2), "presentation")
    if document.string(3) != stem:
        problems.append(f"presentation is named {document.string(3)!r} but its file is {manifest_name!r}")

    cues = document.messages(13)
    if not cues:
        problems.append("presentation has no cues")
    cue_uuids = [uuid(cue.message(1), f"cue {index + 1}") for index, cue in enumerate(cues)]

    for index, cue in enumerate(cues, start=1):
        where = f"cue {index}"
        if not cue.uint(12):
            problems.append(f"{where}: disabled")
        actions = cue.messages(10)
        kinds = [action.uint(9) for action in actions]
        if kinds != [ACTION_PRESENTATION_SLIDE]:
            problems.append(f"{where}: actions are {kinds}, expected one text slide {[ACTION_PRESENTATION_SLIDE]}")
            continue
        action = actions[0]
        uuid(action.message(1), f"{where} slide action")
        if not action.uint(6):
            problems.append(f"{where}: slide action disabled")
        base = action.message(23, 2, 1)
        if base is None:
            problems.append(f"{where}: no slide")
            continue
        canvas = base.message(6)
        if not canvas or canvas.double(1) <= 0 or canvas.double(2) <= 0:
            problems.append(f"{where}: the slide has no size")
        uuid(base.message(7), f"{where} canvas")
        elements = base.messages(1)
        if not elements:
            problems.append(f"{where}: the slide holds no text box")
        for element in elements:
            graphics = element.message(1)
            if graphics is None:
                problems.append(f"{where}: an empty slide element")
                continue
            # ProPresenter's own exports give a template's text box the same
            # identifier on every slide, so these need not be unique.
            uuid(graphics.message(1), f"{where} text box", unique=False)
            text = graphics.message(13)
            if text is None or not text.all(5):
                problems.append(f"{where}: the text box has no text")
                continue
            try:
                shown = rtf_text(text.all(5)[0].decode("latin-1"))
            except Malformed as error:
                problems.append(f"{where}: {error}")
                continue
            length = len(shown.encode("utf-16-le")) // 2
            attributes = text.message(3)
            ranges = [custom.message(1).uint(2) if custom.message(1) else 0
                      for custom in (attributes.messages(13) if attributes else [])]
            if length and not ranges:
                problems.append(f"{where}: {shown!r} has no text attributes")
            for end in ranges:
                if end != length:
                    problems.append(f"{where}: text attributes cover {end} characters, but the text {shown!r} has {length}")

    groups = document.messages(12)
    if not groups:
        problems.append("no groups")
    group_uuids = set()
    grouped = []
    for group in groups:
        group_uuids.add(uuid(group.message(1, 1), "group"))
        name = group.message(1).string(2) if group.message(1) else ""
        if not name:
            problems.append("a group has no name")
        grouped.extend(identifier.string(1) for identifier in group.messages(2))
    for cue_uuid in cue_uuids:
        count = grouped.count(cue_uuid)
        if count != 1:
            problems.append(f"cue {cue_uuid} is in {count} groups, not one")
    for listed in grouped:
        if listed not in cue_uuids:
            problems.append(f"a group lists {listed}, which is not a cue")

    for arrangement in document.messages(11):
        uuid(arrangement.message(1), f"arrangement {arrangement.string(2)!r}")
        for identifier in arrangement.messages(3):
            if identifier.string(1) not in group_uuids:
                problems.append(f"arrangement {arrangement.string(2)!r} names {identifier.string(1)}, which is not a group")

    # Groups are named by every arrangement that repeats them, so only the
    # presentation's own identifiers must be unique.
    seen = set()
    for value in uuids:
        if value and value in seen:
            problems.append(f"UUID {value} is used more than once")
        seen.add(value)
    return len(cues)


def main(arguments):
    if not arguments:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    bundles = []
    for argument in arguments:
        path = Path(argument)
        if path.is_dir():
            bundles.extend(sorted(path.rglob("*.probundle")))
        else:
            bundles.append(path)
    if not bundles:
        print("No .probundle files found in: " + ", ".join(arguments), file=sys.stderr)
        return 1

    failed = 0
    for bundle in bundles:
        if not bundle.is_file():
            print(f"FAIL {bundle}: no such file")
            failed += 1
            continue
        problems, summary = check(bundle)
        print(f"{'FAIL' if problems else 'ok  '} {bundle}: {summary}")
        for problem in problems:
            print(f"     - {problem}")
        failed += bool(problems)
    print(f"\n{len(bundles) - failed} of {len(bundles)} bundles passed.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
