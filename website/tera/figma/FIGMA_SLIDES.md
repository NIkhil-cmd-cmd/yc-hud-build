# Tera — Figma Slides (8-slide deck)

Pitch deck for HUD hackathon submission. Each slide is a **1920×1080** SVG — drag into Figma or Figma Slides.

## Narrative arc

| # | File | Story beat | Speaker hook |
|---|------|------------|--------------|
| 1 | `slide-01-cover.svg` | Brand + promise | "Browser Use takes 68s and 15k tokens every run." |
| 2 | `slide-02-problem.svg` | Cost loop | Show why repeat runs don't get cheaper today. |
| 3 | `slide-03-insight.svg` | Demonstration learning | "You already know how — the browser should remember." |
| 4 | `slide-04-architecture.svg` | Native WKWebView | One window vs external Chromium. |
| 5 | `slide-05-observe.svg` | Passive capture | No record button; observation always on. |
| 6 | `slide-06-compile.svg` | MDP compile | Graph + local storage path. |
| 7 | `slide-07-replay.svg` | Proof | 0 tokens · ~15s vs ~15k · ~68s. |
| 8 | `slide-08-cta.svg` | Demo + links | Live URLs, stack, 2.5 min script. |

## Import

1. Figma → **Presentation 16:9** frame (1920×1080).
2. Drag all 8 SVGs from [`slides/`](slides/) onto the canvas (one per frame).
3. Fonts: [Instrument Serif](https://fonts.google.com/specimen/Instrument+Serif), [DM Sans](https://fonts.google.com/specimen/DM+Sans).
4. Export: **PDF** (4-up submission) or **PNG @2x**.

## Design system

See [`slides/_shared-styles.txt`](slides/_shared-styles.txt).

- Background `#090909` with radial accent meshes (amber / teal / violet)
- Safe margin **100px**
- Labels: DM Sans 11px, uppercase, 14% tracking
- Headlines: Instrument Serif 68–132px, -2% tracking
- Cards: `#141414`, 1px `rgba(255,255,255,0.08)` border, 24–28px radius
- Positive accent: `#12A884` · Warm accent: `#C4A484`

## Export checklist

- [ ] PDF 8 pages for submission upload
- [ ] Align with [`docs/DEMO_SCRIPT.md`](../../docs/DEMO_SCRIPT.md) timing
- [ ] Replace benchmark numbers if `validate_claims.py` updates metrics

## Related

- Live site: https://tera-zeta-ten.vercel.app
- Repo: https://github.com/NIkhil-cmd-cmd/yc-hud-build
- Submission copy: [`docs/SUBMISSION.md`](../../docs/SUBMISSION.md)
