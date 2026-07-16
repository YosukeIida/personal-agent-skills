#!/usr/bin/env python3
"""Tight-crop white-background generated assets and optionally make a contact sheet."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageOps


VALID_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff"}


def collect_inputs(inputs: list[Path]) -> list[Path]:
    files: list[Path] = []
    for item in inputs:
        if item.is_dir():
            files.extend(p for p in sorted(item.iterdir()) if p.suffix.lower() in VALID_EXTENSIONS)
        elif item.is_file() and item.suffix.lower() in VALID_EXTENSIONS:
            files.append(item)
        else:
            raise FileNotFoundError(f"not an image file or directory: {item}")
    return files


def ink_bbox(img: Image.Image, threshold: int) -> tuple[int, int, int, int] | None:
    gray = img.convert("L")
    ink_mask = gray.point(lambda value: 255 if value < threshold else 0, mode="L")
    return ink_mask.getbbox()


def threshold_line_art(img: Image.Image, threshold: int) -> Image.Image:
    gray = img.convert("L")
    return gray.point(lambda value: 0 if value < threshold else 255, mode="L")


def add_padding(img: Image.Image, padding: int) -> Image.Image:
    if padding <= 0:
        return img
    return ImageOps.expand(img, border=padding, fill=255)


def square_canvas(img: Image.Image) -> Image.Image:
    size = max(img.size)
    canvas = Image.new("L", (size, size), 255)
    canvas.paste(img, ((size - img.width) // 2, (size - img.height) // 2))
    return canvas


def resize_max(img: Image.Image, max_size: int | None) -> Image.Image:
    if not max_size or max(img.size) <= max_size:
        return img
    out = img.copy()
    out.thumbnail((max_size, max_size), Image.Resampling.LANCZOS)
    return out


def crop_one(path: Path, out_dir: Path, threshold: int, padding: int, make_square: bool, max_size: int | None) -> Path:
    img = Image.open(path)
    bbox = ink_bbox(img, threshold)
    if bbox is None:
        raise ValueError(f"no ink found in {path}")
    bw = threshold_line_art(img, threshold)
    cropped = bw.crop(bbox)
    cropped = add_padding(cropped, padding)
    if make_square:
        cropped = square_canvas(cropped)
    cropped = resize_max(cropped, max_size)
    out_path = out_dir / f"{path.stem}.png"
    cropped.save(out_path, format="PNG", optimize=True)
    return out_path


def make_contact_sheet(paths: list[Path], out_path: Path, thumb: int, columns: int) -> None:
    if not paths:
        return
    rows = (len(paths) + columns - 1) // columns
    sheet = Image.new("L", (columns * thumb, rows * thumb), 255)
    for index, path in enumerate(paths):
        img = Image.open(path).convert("L")
        img.thumbnail((thumb - 20, thumb - 20), Image.Resampling.NEAREST)
        x = (index % columns) * thumb + (thumb - img.width) // 2
        y = (index // columns) * thumb + (thumb - img.height) // 2
        sheet.paste(img, (x, y))
    sheet.save(out_path, format="PNG", optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", nargs="+", required=True, type=Path, help="Input image files or directories.")
    parser.add_argument("--out-dir", required=True, type=Path, help="Output directory for cropped PNG assets.")
    parser.add_argument("--threshold", type=int, default=218, help="Pixels darker than this are treated as ink.")
    parser.add_argument("--padding", type=int, default=0, help="White padding to add after tight crop.")
    parser.add_argument("--square", action="store_true", help="Place each crop on a square white canvas.")
    parser.add_argument("--max-size", type=int, default=None, help="Downscale long edge to this size after cropping.")
    parser.add_argument("--contact-sheet", action="store_true", help="Create _contact_sheet.png in the output dir.")
    parser.add_argument("--contact-thumb", type=int, default=220, help="Contact sheet cell size.")
    parser.add_argument("--contact-columns", type=int, default=3, help="Contact sheet column count.")
    args = parser.parse_args()

    if not 1 <= args.threshold <= 255:
        raise ValueError("--threshold must be between 1 and 255")
    args.out_dir.mkdir(parents=True, exist_ok=True)
    inputs = collect_inputs(args.input)
    outputs = [
        crop_one(path, args.out_dir, args.threshold, args.padding, args.square, args.max_size)
        for path in inputs
    ]
    if args.contact_sheet:
        make_contact_sheet(outputs, args.out_dir / "_contact_sheet.png", args.contact_thumb, args.contact_columns)
    for output in outputs:
        with Image.open(output) as img:
            print(f"{output}: {img.size[0]}x{img.size[1]} {img.mode}")


if __name__ == "__main__":
    main()
