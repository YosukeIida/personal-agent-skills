---
name: grant-figure-assets
description: Create reusable monochrome figure assets for Japanese academic grant proposals such as JSPS DC1. Use when Codex needs to generate an overview/reference figure or icon set with imagegen, save raw PNGs, tight-crop them by bounding box, make contact sheets, or prepare black-and-white assets for HTML/CSS/SVG reconstruction of proposal figures.
allowed-tools: Bash(uv:*), Read, Write
---

# Grant Figure Assets

## Workflow

Use this skill together with `imagegen` for proposal figure materials.

1. Decide the asset strategy:
   - For layout exploration, generate one full reference infographic first.
   - For reusable HTML assets, prefer one icon per generation rather than cropping a gridded sheet when borders, labels, or uneven placement would contaminate crops.
   - Use a gridded sheet only for rough style exploration or when the user explicitly wants a sheet.
2. Generate raw images with `imagegen`.
   - Save raw outputs under a project-local directory such as `figs/icon_assets/<batch>_raw/`.
   - Do not leave project assets only under `$CODEX_HOME/generated_images`.
3. Tight-crop raw images with `scripts/tight_crop_assets.py`.
   - Use a white-background threshold to find the non-white bounding box.
   - Save cropped assets under a sibling directory such as `figs/icon_assets/<batch>_tight/`.
   - Create a contact sheet for visual QA.
4. Inspect the contact sheet with `view_image`.
   - Regenerate any asset whose concept is wrong, whose edges are cropped, or whose image has unwanted labels/borders.
   - Re-run the crop script only for the changed assets or the whole raw folder.
5. Report the saved paths and any assets that were intentionally superseded.

## Prompt Rules

For JSPS/DC1-style monochrome assets:

- Use black line art on pure white background.
- Prefer crisp, print-safe, simple but recognizable illustrations over generic icon symbols.
- Ask for square canvas and no outer frame, no grid, no labels unless labels are intentionally part of the asset.
- State that the object should fill roughly 70-80% of the canvas with about 10% padding.
- For HTML reconstruction, keep text labels in HTML/CSS whenever possible and keep PNG assets label-free.
- If a generated sheet includes grid lines, labels, or inconsistent placement, switch to individual generation.

### Single-object rule (mandatory for HTML reconstruction)

When the target figure will be reconstructed in HTML/CSS/SVG (as opposed to being
used as a standalone illustration), every PNG asset MUST be a single,
self-contained object. Do not pack a process or a flow into one PNG. This is the
most common failure mode for proposal figures and is non-negotiable.

Concretely:

- **One asset = one object.** If the concept involves "input → process → output",
  it is three objects. Generate three separate PNGs (input object, process object,
  output object) and let HTML add the arrows between them.
- **No arrows inside the PNG.** Arrows are layout, not content. They belong in
  HTML/CSS/SVG, not in raster assets.
- **No paired "before/after" depictions.** A "compression" icon should not show
  a big document next to a small document with an arrow. It should be either
  the big document alone or the small document alone — pick one and generate
  the other separately if needed.
- **No composed scenes.** "Brain reading a document" = brain + document =
  two objects = two PNGs.
- **No decorative satellites.** An LLM icon should not be a brain with orbiting
  atoms / sparkles / dotted halos. It should be just the brain (or just the
  network graph) and nothing else.
- **Style must match the existing batch.** If the user references an existing
  icon set (e.g. `01_pos_system.png` ... `12_model_size_package.png`), every new
  asset must read at the same visual weight: same stroke width, same level of
  detail, same "single recognizable noun" framing. Look at one or two of the
  existing icons via `view_image` before drafting prompts.

If the user's asset list violates this rule (e.g. asks for "X → Y → Z" in one
icon), push back and propose a decomposed list before generating. Do not silently
generate a flow diagram and hope for the best — the resulting assets will be
unusable for HTML reconstruction and will need to be regenerated.

### Reference figure scale check

If a reference figure is provided (e.g. a GPT Image 2 mockup of the target
infographic), measure how much pixel area each pictogram occupies in the
reference. Pictograms that occupy ~80×80 px in the reference must be generated
as simple, sparse symbols — not as fully-rendered illustrations scaled to
1024×1024 — because the generator will fill extra canvas with decorative
elements (arrows, sub-parts, orbital decorations) that break the single-object
rule. When in doubt, ask the generator for "sparse line art, 30%+ whitespace,
single centered symbol, no secondary elements."

Read `references/prompts.md` only when you need reusable prompt templates for full figures, icon sheets, or individual icon regeneration.

## Cropping

Run the script with `uv` so Pillow does not need to be globally installed:

```bash
uv run --with pillow python /Users/yosuke/.codex/skills/grant-figure-assets/scripts/tight_crop_assets.py \
  --input path/to/raw-assets \
  --out-dir path/to/tight-assets \
  --threshold 218 \
  --contact-sheet
```

Useful options:

- `--padding 0`: true bounding-box crop with no extra whitespace.
- `--padding 8`: small margin for icons that visually need breathing room.
- `--square`: center each crop on a square white canvas after tight cropping.
- `--max-size 1024`: downscale long edges after cropping.
- `--threshold`: pixels darker than this are treated as ink.

Use `--threshold 218` as a default for generated white-background line art. Increase it if faint gray lines should count as ink; decrease it if background haze is being included.

## Quality Checks

Before finishing, verify:

- No grid lines, crop guides, or sheet borders are present in individual assets.
- Important strokes are not cut off at the top, bottom, left, or right.
- The background is white and the asset is grayscale or black-and-white.
- The icon concept is specific enough for the proposal text, for example POS register rather than a generic database when the user asked for POS.
- The contact sheet makes all assets recognizable at the target display size.
