# Tera Browser — Marketing Website

Marketing site for **Tera browser**. Implements the Midu-structure plan with an editorial earth/nature aesthetic. The macOS app remains branded OpenHive internally until a future rebrand.

## Stack

Vite + React with real shader libraries:

| Library | Use |
|---------|-----|
| [@shadergradient/react](https://github.com/ruucm/shadergradient) | Hero + testimonials WebGL gradient (grain on) |
| [@paper-design/shaders-react](https://www.npmjs.com/package/@paper-design/shaders-react) | LiquidMetal logo, GrainGradient card art |
| SVG feTurbulence + feDisplacementMap | Liquid glass nav, cards, pricing |

```bash
cd website/tera && npm install && npm run dev
```

## Live site

**Production:** https://tera-zeta-ten.vercel.app

**Vercel project:** [tera](https://vercel.com/nikhilcmdcmds-projects/tera) — connected to [yc-hud-build](https://github.com/NIkhil-cmd-cmd/yc-hud-build) (root: `website/tera`, branch: `graphvisualization`)

## Live preview (local)

```bash
cd website/tera
python3 -m http.server 8080
# open http://localhost:8080
```

Deploy the `website/tera/` folder to any static host (Vercel, Netlify, GitHub Pages, Framer custom code embed).

## Framer workflow

The plan specified Framer as the primary build tool. This repo includes:

| Path | Purpose |
|------|---------|
| [website/tera/framer/BUILD_GUIDE.md](../website/tera/framer/BUILD_GUIDE.md) | Import tokens, motion presets, asset list |
| [website/tera/design/tokens.css](../website/tera/design/tokens.css) | CSS custom properties |
| [website/tera/design/unsplash-manifest.json](../website/tera/design/unsplash-manifest.json) | Curated photography with credits |
| [website/tera/index.html](../website/tera/index.html) | Full reference implementation (all sections) |

Use `index.html` as the pixel and interaction reference when rebuilding in Framer, or ship it directly.

## Brand tokens

| Token | Hex |
|-------|-----|
| terra-stone | `#F4F0EA` |
| terra-clay | `#C4A484` |
| terra-moss | `#3D4F3A` |
| terra-bark | `#2A2420` |
| terra-fog | `#E8E4DC` |
| terra-slate | `#5C6B5A` |
| terra-ember | `#8B6914` |
| terra-lichen | `#7A8B72` |

**Typography:** Instrument Serif (display) + DM Sans (body)

## CTAs

| Action | URL |
|--------|-----|
| Download (Free tier) | https://github.com/nook-browser/nook/releases/download/v1.0.2/Nook-v1.0.2.dmg |
| GitHub | https://github.com/nook-browser/Nook |
| Pro / Team waitlist | Client-side form (wire to Notion/Airtable/Formspree in Framer) |

## Sections (Midu order)

1. Sticky nav + mobile overlay
2. Hero with parallax terrain (Unsplash)
3. About + CTA
4. Browser mockup carousel
5. Highlights grid (4 cards)
6. Testimonial carousel
7. Stack marquee
8. Feature cards (4 expandable)
9. Pricing keycaps (Free / Pro waitlist / Team waitlist)
10. FAQ accordion
11. Footer bookend

## Assets

- Wordmark + keycaps: `website/tera/assets/`
- App mockups: `website/tera/assets/screenshots/` (replace SVG placeholders with retina PNGs from live app)
- OG image: `website/tera/assets/og-image.svg` (export PNG 1200x630 for social)

## Photography credits

See [unsplash-manifest.json](../website/tera/design/unsplash-manifest.json). Footer links: Denny Müller, Stefan Stefancik, Luca Bravo on Unsplash.

## Domain

Set when ready: `tera.browser`, `gettera.com`, or similar. Update `og:url` and Framer publish settings.

## Demo URL (hackathon)

Update [SUBMISSION.md](SUBMISSION.md) `Demo URL` when deployed:

```
https://<your-domain>/
```
