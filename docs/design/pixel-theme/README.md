# Pixel style (“像素 · 深色”)

The pixel style is a third look, next to “夜幕 · 深色” (ink, still the default) and “云蓝 · 浅色” (light). Pick it in Settings. It is saved under the same preference key, `studioThemeV06`, with the value `pixel`. It uses the dark system appearance.

## Palette

The pixel art is deeper and more saturated than the ink artwork, so the style has its own palette. Ink's graphite navy and teal looked flat next to it. This palette is an arcade night: a deep indigo canvas, warm white text, and accents close to the PICO-8 palette.

| Token | Pixel value | Ink value, for comparison |
| --- | --- | --- |
| `paper` | `#080B1E` | `#0B1826` |
| `sidebar` | `#0C1029` | `#13202D` |
| `surface` | `#111737` | `#1A2532` |
| `raised` | `#1A2350` | `#222D3A` |
| `input` | `#0F1433` | `#1C2836` |
| `border` | `#2A3672` | `#2B3746` |
| `primaryText` | `#F4F1EA` | `#F2F5F8` |
| `secondaryText` | `#9AA4D2` | `#A9B4C2` |
| `blue` (accent) | `#29ADFF` | `#4DB293` |
| `actionFill` | `#1D63D8` | `#2F8170` |

Workspace colors:

| Workspace | Color |
| --- | --- |
| Video | `#FF9A1F` |
| Audio | `#A66BFF` |
| Code | `#29ADFF` |
| Design | `#2BD46F` |

The “新建…任务” buttons are solid blocks in these colors with dark text (`#0B0E22`), which keeps the contrast at 5:1 or better. Primary buttons such as 添加员工 keep white text on `actionFill`.

## Shapes and type

- **Stepped corners.** `StudioShape(radius, pixel:)` draws a rectangle whose corners step in twice, like an 8-bit window frame. The step is radius ÷ 4, between 2 and 4 pt. The other styles get the usual rounded rectangle from the same call.
- **Borders and shadows.** Borders are 2 pt. Shadows are hard: offset 4 pt right and down, no blur, cast by the element's outline only (`studioShadow`).
- **Block buttons.** `PixelBlockBackground` is a solid fill with a lit top edge and a shaded bottom edge.
- **Type.** Latin text uses the monospaced system font: the sidebar wordmark, the banner line `> Make room for ideas_`, and the captions. Chinese text keeps the system font, since macOS has no pixel CJK font. The banner title gets a hard blue shadow.
- **Caption plates.** Card and banner captions sit on small dialog-box plates (`pixelPlate`), so they stay readable over busy art.
- **Grid.** A faint 24 pt grid sits behind the pages, echoing the floor grid in the artwork.

So far this covers the sidebar, header, home banner and cards, composer, primary buttons, search fields, settings options, page panels and employee cards. Project cards, the inspector and sheets use the pixel colors but keep rounded corners.

## Artwork

| File | Asset | Shown in |
| --- | --- | --- |
| `hero` | `StudioHeroPixel` | Home banner |
| `video` | `StudioVideoPixel` | Video workspace card |
| `audio` | `StudioAudioPixel` | Audio workspace card |
| `code` | `StudioCodePixel` | Code workspace card |
| `design` | `StudioDesignPixel` | Design workspace card |

The sources are the five images the user supplied, kept as WebP in `artwork/`. To install them:

```bash
python3 -I scripts/install_dark_artwork.py --style pixel --trim 8
```

`--trim 8` cuts 8 px from every edge. The audio, code and design sources carry a thin light frame of 2–6 px on their top and left edges, left over from screenshots.

The images use the same layout rules as the ink artwork (see [the dark theme note](../dark-theme/README.md)). If a pixel image is missing, that slot falls back to the ink artwork, and then to the drawn stand-in.

## How the switch works

- `Theme.pixelActive` tells the dark branch of each color which palette to use. `WorkbenchView` sets it from the saved style before its content draws.
- Ink and pixel share the dark appearance, so changing between them would not redraw colors on its own. The window content therefore takes a new identity per style (`.id(style)`). This keeps the page you are on. Terminal sessions are unaffected, because their views live in `TerminalSession`.
- Views read the style from the `studioStyle` environment value.

## Checks

`zsh scripts/render_theme_preview.sh` now writes 16 renders. Six are pixel pages: home at 1440×900 and 1100×720, empty home, AI 员工, 工具连接 and 设置. It also renders the ink home again after the pixel renders, and checks two things:

- Ink looks the same after switching back from pixel.
- Pixel uses a different palette.
