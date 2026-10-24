# Dark theme (default)

Workbench now opens in “夜幕 · 深色” (dark). Settings can switch it to “云蓝 · 浅色” (light). The choice is stored under the preference key `studioThemeV06` and does not follow the system appearance.
A light choice saved by older builds under `studioThemeV04` is no longer read, so after updating the app starts in dark.

The pixel style (“像素 · 深色”) is a second dark style with its own palette and artwork. See [the pixel style note](../pixel-theme/README.md).

## Colors

The colors are defined in `Theme` (`Sources/WorkbenchApp/WorkbenchView.swift`). Each value is a light/dark pair.

| Token | Dark value | Used for |
| --- | --- | --- |
| `paper` | `#0B1826` | Page background (deep navy) |
| `sidebar` | `#13202D` | Sidebar, slightly lighter than the page |
| `surface` | `#1A2532` | Card side panels, settings panels |
| `raised` | `#222D3A` | Task rows, selected sidebar item, composer buttons |
| `input` | `#1C2836` | Composer bar, search fields |
| `border` | `#2B3746` | Card, field and divider lines |
| `primaryText` | `#F2F5F8` | |
| `secondaryText` | `#A9B4C2` | |
| `actionFill` | `#2F8170` | Primary buttons (添加 CLI, 添加员工 …) |

The four default workspaces use brighter colors in dark mode:

- Video `#F37A3A`
- Audio `#7D67EC`
- Code `#3E8FF5`
- Design `#3E9A7F`

The “新建…任务” button is a horizontal gradient pill from the accent to the workspace color, with a glow in the same color. Custom workspaces keep the color the user picked.

## Artwork

Dark artwork is a separate set of images, not the light artwork with a filter.

| File | Asset | Minimum size | Shown in |
| --- | --- | --- | --- |
| `hero` | `StudioHeroDark` | 1600×600 | Home banner. The focus sits at about 66% of the width and the left side fades into the page. |
| `video` | `StudioVideoDark` | 900×700 | Video workspace card |
| `audio` | `StudioAudioDark` | 900×700 | Audio workspace card |
| `code` | `StudioCodeDark` | 900×700 | Code workspace card |
| `design` | `StudioDesignDark` | 900×700 | Design workspace card |

To install:

1. Put the images in `docs/design/dark-theme/artwork/`, named as in the table. PNG, JPG and WebP all work, for example `hero.png`.
2. Run `python3 -I scripts/install_dark_artwork.py`. It checks the sizes and writes each image as PNG into `Assets.xcassets/<asset>.imageset`.
3. Rebuild, then run `zsh scripts/render_theme_preview.sh` to check the result.

If an asset is missing, the app draws a stand-in from `Sources/WorkbenchApp/DarkArtwork.swift`:

- Banner: a glowing AI sphere with an orbit ring and glass panels.
- Cards: the workspace's object glowing on a glass podium, with icon panels on both sides.

Layout:

- **Card artwork** is scaled to the width of the card's art area and placed on the bottom edge. In wide cards it sinks about 10% further, which crops some of the reflective floor.
- **Above a card image**, the space is filled with the average color of the image's top strip. The image fades into it, so the title and description sit on a calm area.
- **The banner** is cropped more from the bottom than the top, so the whole sphere stays visible.

For a new card image, keep the object in the middle to lower middle and the top edge dark. Leave the bottom-right corner fairly calm for the calligraphy line.

The current five images were supplied by the user, and their sources are in `artwork/`.

## Checks

`scripts/render_theme_preview.sh` writes 9 offscreen renders to `work/theme-qa`: 7 in dark and 2 in light. On the dark home render it also checks the brightness of the sidebar and the banner.

Offscreen snapshots cannot draw `rotation3DEffect`; those layers end up in the top-left corner. The stand-in art therefore tilts its panels with a 2D shear (`Skew`).
