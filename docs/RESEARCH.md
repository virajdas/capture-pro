# What makes a screen recording feel "premium"

Notes behind Capture Pro's defaults. Screen Studio's own docs name its controls (spring tension/friction/mass, cursor size, auto-zoom) but publish no numbers. The most concrete reference is the open-source [Cap](https://github.com/CapSoftware/Cap) recorder, whose presets mirror Screen Studio's. Values marked *(est.)* are our own judgment.

## 1. Record raw, decorate later

Capture the screen **without the system cursor**, and log cursor position (~120 Hz), clicks, keystroke timing and cursor shape separately. Every effect then becomes a pure function of time, applied after recording:
- smoothing
- zoom
- ripples
- backgrounds

So every setting stays editable, and preview and export are identical.

## 2. Auto-zoom

| Rule | Value | Source |
|---|---|---|
| Lead-in before a click | 0.3 s (Cap); we use **0.45 s** | Cap `editor_edits.rs` |
| Hold after a click | 2.5 s (Cap); we use **2.0 s** | Cap |
| Merge zooms whose gap is ≤ | **2.5 s** | Cap |
| Default zoom level | **2.0×** | Cap |
| Ignore clicks in the last | **1 s** | Cap |
| Collapse double-clicks within | **0.4 s** | *(est.)* |
| Ignore right-clicks | yes | Cap discussion |
| Typing burst (keys < 1.5 s apart, ≥ 1 s long) zooms on last click | yes | *(est.)*, Screen Studio has typing detection |
| Very wide clusters (> 70 % of screen) zoom slightly less | 0.8× | *(est.)* |

## 3. Camera

> Capture Pro 1.1 replaced the spring-driven zoom with eased transitions. Springs chasing
> step targets felt snappy, and with zoom and pan on independent springs they swooped
> sideways. Each zoom is now three phases. First, an eased zoom-in interpolated in log-scale
> space about the one point that stays fixed between the start and end framings. Second, a
> hold where a critically damped spring pans after the cursor. Third, an eased zoom-out.
> The curves are cubic Béziers, and the default "Smooth" is `(0.42, 0, 0.18, 1)`, with
> 0.9 s in and 1.1 s out. Camera motion blur is now off by default. The notes below
> describe the spring approach, which still drives the pan.

- **Spring setup:**
  - One spring each for zoom level, x and y.
  - Each spring chases a step target and keeps its velocity when the target changes, so nothing has a fixed duration.
  - Cap's movement spring is `k = 200, c = 40, m = 2.25`, which is a response of about 0.67 s at ζ ≈ 0.94. We default to **0.7 s / 0.95**.
- **Pre-aim:** while fully zoomed out, the camera centre snaps to the next zoom's focus. A zoom-in then scales straight toward its target instead of drifting sideways.
- **Zoom-out:** keeps the last centre, so the frame doesn't re-aim mid-flight.
- **Follow:** the camera only re-aims when the cursor leaves the central **70 %** of the zoomed view. It aims at the average cursor position over the next **0.5 s**.
- **Clamping:** the viewport is clamped to the frame, so empty space never shows.
- **Motion blur:** a short radial blur while zooming and a directional blur while panning, both proportional to camera velocity.

## 4. Cursor

- **Smoothing:**
  - A spring, not a lerp. Cap's "Mellow" preset is `k = 470, c = 70, m = 3` (≈ 0.5 s response).
  - A spring trails a moving target by about `c/k` seconds. We sample the target that far ahead to cancel the lag.
- **Near clicks:** within 200 ms of a click, a stiffer spring takes over so the cursor lands exactly on the click.
- **Size:** about **1.5–2×** the logical size reads well on video. Cap switches to 2× when auto-zoom is on. We default to **1.6×**.
- **Press:** scale to **0.8×** over 130 ms, then recover.
- **Ripple:** ring radius about **1.25×** the cursor height, lasting **0.6 s**, with ease-out growth and a linear fade.
- **Idle:** hide after **2 s**, fade out over **0.4 s**, and fade back in **0.25 s** before movement resumes.
- **Flicker:** cursor shapes that last under 80 ms are dropped.
- **Shapes:** each shape is re-rendered at 6× from the system's vector cursor, with a soft shadow.

## 5. Frame

- **Padding:** 6–10 % of the shorter side *(est.)*. We default to **8 %**.
- **Corners:** 12–16 px at 1080p *(est.)*. We default to **14 px**.
- **Shadow:** large and soft — blur ≈ 40 px, opacity 0.35–0.5, y-offset 12–20 px *(est.)*.
- **Edge:** a 1 px light inner edge stops dark UIs from melting into dark backgrounds.
- **Backgrounds:** a few adjacent hues drifting slowly (one cycle every 20–40 s), with a soft warp and **fine grain**. The grain hides gradient banding after compression. Cap's default animated palette ("Cool Candy") is ours too.

## 6. Smoothness

- **Frames:** capture at the display's refresh rate, up to 120 Hz. App animations then don't beat against a 60 Hz sampling grid, and export picks evenly spaced frames from the denser stream.
- **Cursor:** positions come from real mouse events with their own timestamps. Polling a timer adds jitter that a spring can only partly hide.
- **Live preview:** uses bilinear resampling. Export keeps the slower Lanczos resampling for crisp text.

## 7. Export

- **Frame rate:** 60 fps, as Screen Studio recommends.
- **Bitrate:** bits per pixel × width × height × fps.

| Preset | Bits per pixel | 1440p60 bitrate |
|---|---|---|
| Web | 0.08 | — |
| High (default) | 0.16 | ≈ 35 Mbps |
| Maximum | 0.30 | — |

- **Keyframes:** every 2 s.
- **GIF:** 15 fps and 800–1000 px wide.
- **Raw capture:** HEVC at about 0.22 bpp. H.264 can't encode 5K/6K Retina frames.

## Sources

- github.com/CapSoftware/Cap: `crates/project/src/configuration.rs`, `crates/rendering/src/zoom_spring.rs`, `cursor_interpolation.rs`, `layers/cursor.rs`, `apps/desktop-gpui/src/editor_edits.rs`, PR #1106
- screen.studio/guide: auto-zoom, animations, cursor, export settings, typing segments
- github.com/pythonlearner1025/Screen-Studio-Effects
- WWDC23 "Animate with springs"
