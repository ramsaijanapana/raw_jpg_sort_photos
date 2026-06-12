#!/usr/bin/env python3
"""
sort_photos.py — Sorts RAW and JPG photo files into subfolders.

Usage:
    python sort_photos.py
        Sorts the folder this script lives in, into RAW/ and JPG/ subfolders there.

    python sort_photos.py /path/to/input
        Sorts the given folder, placing RAW/ and JPG/ subfolders inside it.

    python sort_photos.py /path/to/input /path/to/output
        Reads photos from input, places RAW/ and JPG/ inside output folder.

Supported RAW formats: ARW, CR2, CR3, NEF, RAF, ORF, DNG, RW2, PEF, SRW
Supported JPG formats: JPG, JPEG

Works on macOS, Windows, and Linux. Requires Python 3.6+.
"""

import sys
import shutil
from pathlib import Path

RAW_EXTENSIONS = {".arw", ".cr2", ".cr3", ".nef", ".raf", ".orf", ".dng", ".rw2", ".pef", ".srw"}
JPG_EXTENSIONS = {".jpg", ".jpeg"}


def sort_photos(input_folder: Path, output_folder: Path):
    raw_dir = output_folder / "RAW"
    jpg_dir = output_folder / "JPG"

    # Move when sorting in-place; copy when writing to a separate output folder
    same_folder = input_folder.resolve() == output_folder.resolve()
    action = shutil.move if same_folder else shutil.copy2
    verb = "moved" if same_folder else "copied"

    count_raw = 0
    count_jpg = 0
    skipped = 0

    files = [f for f in input_folder.iterdir() if f.is_file()]

    if not files:
        print("No files found in the input folder.")
        return

    for file in files:
        ext = file.suffix.lower()
        if ext in RAW_EXTENSIONS:
            raw_dir.mkdir(parents=True, exist_ok=True)
            dest = raw_dir / file.name
            if dest.exists():
                print(f"  Skipped (already exists): {file.name}")
                skipped += 1
            else:
                action(str(file), str(dest))
                count_raw += 1
        elif ext in JPG_EXTENSIONS:
            jpg_dir.mkdir(parents=True, exist_ok=True)
            dest = jpg_dir / file.name
            if dest.exists():
                print(f"  Skipped (already exists): {file.name}")
                skipped += 1
            else:
                action(str(file), str(dest))
                count_jpg += 1
        # Other file types are left in place

    print(f"\nDone!")
    print(f"  RAW files {verb} : {count_raw}")
    print(f"  JPG files {verb} : {count_jpg}")
    if skipped:
        print(f"  Skipped (dupes)  : {skipped}")
    if count_raw or count_jpg:
        print(f"\n  Output location  : {output_folder.resolve()}")


if __name__ == "__main__":
    args = sys.argv[1:]

    if len(args) >= 2:
        input_folder  = Path(args[0])
        output_folder = Path(args[1])
    elif len(args) == 1:
        input_folder  = Path(args[0])
        output_folder = input_folder
    else:
        # Double-click default: sort the folder the script lives in
        input_folder  = Path(__file__).parent
        output_folder = input_folder

    if not input_folder.is_dir():
        print(f"Error: input path '{input_folder}' is not a valid directory.")
        sys.exit(1)

    output_folder.mkdir(parents=True, exist_ok=True)

    print(f"Input  : {input_folder.resolve()}")
    print(f"Output : {output_folder.resolve()}\n")
    sort_photos(input_folder, output_folder)
