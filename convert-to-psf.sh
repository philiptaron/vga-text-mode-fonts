#!/usr/bin/env bash
# Convert raw VGA bitmap fonts to PSF1 format for Linux console
# PSF1 header: 0x36 0x04 (magic), mode (0x00=256 glyphs), height

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/FONTS"
DST_DIR="$SCRIPT_DIR/PSF"

count=0

# Find all font files and convert them
find "$SRC_DIR" -type f -name '*.F[0-9][0-9]' | while read -r fontfile; do
    # Extract height from extension (e.g., .F16 -> 16)
    ext="${fontfile##*.}"
    height="${ext#F}"
    # Remove leading zero if present (e.g., 08 -> 8)
    height=$((10#$height))

    # Calculate relative path from SRC_DIR
    relpath="${fontfile#$SRC_DIR/}"
    # Change extension to .psf
    relpath_psf="${relpath%.*}.psf"

    # Create output directory
    outfile="$DST_DIR/$relpath_psf"
    mkdir -p "$(dirname "$outfile")"

    # Create PSF1 header and concatenate with font data
    # Header: magic (2 bytes) + mode (1 byte) + height (1 byte)
    printf '\x36\x04\x00' > "$outfile"
    printf "\\x$(printf '%02x' "$height")" >> "$outfile"
    cat "$fontfile" >> "$outfile"

    echo "Converted: $relpath -> PSF/$relpath_psf (height=$height)"
    count=$((count + 1))
done

echo "Done! Converted $count fonts to PSF format in $DST_DIR"
