# Photo Sorter

Cross-platform script to automatically sort RAW and JPG photo files into subfolders.

## Files

| File | Purpose |
|------|---------|
| `sort_photos.py` | Main script (requires Python 3.6+) |
| `sort_photos.command` | One-click launcher for **macOS** |
| `sort_photos.bat` | One-click launcher for **Windows** |

## Usage

### One-click
Drop all three files into your photo folder and double-click the launcher for your OS.

### Command line

```bash
# Sort the folder the script lives in
python sort_photos.py

# Sort a specific folder in-place
python sort_photos.py /path/to/photos

# Copy sorted files to a separate output folder
python sort_photos.py /path/to/input /path/to/output
```

## Supported formats

- **RAW:** ARW, CR2, CR3, NEF, RAF, ORF, DNG, RW2, PEF, SRW
- **JPG:** JPG, JPEG
