# Prompt Templates

## Individual Monochrome Asset

```text
Use case: infographic-diagram
Asset type: standalone high-clarity raster asset for a JSPS DC1 grant proposal infographic
Style: Clean 2D flat line art, BLACK lines on PURE WHITE background. Stroke weight: about 4-5 px, consistent throughout. Square canvas 1024 x 1024. The icon fills roughly 70-80% of the canvas, centered, no border or frame around the canvas edge. No label text below the icon. No color, no gray fill, no shadows, no gradients, no photographic style. Edge-to-edge padding about 10% on each side, no grid lines, no extra elements outside the main icon. Match realistic-but-simple line drawings used in academic infographic icons.

Subject: <specific object/concept>.

Details:
- <visual feature 1>
- <visual feature 2>
- <visual feature 3>

Constraints: no labels unless explicitly requested, no outer frame, no extra decorative elements.
```

## Full Reference Figure

```text
Use case: infographic-diagram
Asset type: reference infographic for a Japanese academic research grant proposal
Create a clean, information-dense, flat-design monochrome figure. Use only black, white, and grays. Pure white background. No color, no photos, no shadows, no gradients, no hand-drawn style. Use clear section headers, thin borders, compact labels, simple monochrome icons, solid arrows for factual flows, dashed arrows for future or hypothetical flows, and bold text or thick borders for emphasis.

Layout:
- <stage/section structure>
- <required sub-elements>
- <labels and captions>

Final output should be useful as a visual reference for later HTML/CSS/SVG reconstruction.
```

## Icon Sheet Exploration

Use only when the user explicitly wants a sheet or when exploring a shared style. Avoid using a sheet as the final source for HTML icons if grid lines or labels will be hard to remove.

```text
Create a monochrome icon sheet for a Japanese academic proposal figure. Arrange <N> icons in a clean grid on pure white background. Use black line art, consistent stroke weight, no color, no shadows, no gradients. Add thin light-gray grid lines only if the user wants visual separation. If the sheet will be cropped into final assets, omit labels and leave generous padding.
```
