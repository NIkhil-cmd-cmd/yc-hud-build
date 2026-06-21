# Tera Brand — Framer Import Guide

Design foundation for the Tera browser marketing site. Import these tokens and assets into Framer before building sections.

## Palette

| Token | Hex | Use |
|-------|-----|-----|
| terra-stone | `#F4F0EA` | Page background |
| terra-clay | `#C4A484` | Warm accent |
| terra-moss | `#3D4F3A` | Deep green accent |
| terra-bark | `#2A2420` | Primary text |
| terra-fog | `#E8E4DC` | Dividers |
| terra-slate | `#5C6B5A` | Secondary text |
| terra-ember | `#8B6914` | CTA / Free keycap |
| terra-lichen | `#7A8B72` | Tertiary accent |

CSS variables: [`tokens.css`](tokens.css)

## Typography

- **Display:** Instrument Serif — hero headlines, footer bookend
- **Body:** DM Sans — paragraphs, nav, cards
- **Micro labels:** DM Sans 11px uppercase, letter-spacing 0.12em

## Photography

Curated Unsplash set with URLs and credits: [`unsplash-manifest.json`](unsplash-manifest.json)

**Treatment in Framer:** Image filter saturation 80%, overlay gradient `linear-gradient(to bottom, transparent 40%, #2A2420 100%)` on hero.

## SVG Assets

| File | Use |
|------|-----|
| `../assets/wordmark.svg` | Nav + footer logo |
| `../assets/keycap-ember.svg` | Free tier pricing |
| `../assets/keycap-moss.svg` | Pro tier pricing |
| `../assets/keycap-slate.svg` | Team tier pricing |
| `../assets/mockup-agent-home.svg` | Browser mockup slide 1 |
| `../assets/mockup-workflow-graph.svg` | Browser mockup slide 2 |
| `../assets/mockup-notch.svg` | Agent notch overlay |
| `../assets/og-image.svg` | Social share (export PNG 1200x630) |

Replace mockup SVGs with retina PNGs from `../assets/screenshots/` when captured from the app.

## Framer Breakpoints

- Desktop: 1440px (primary)
- Tablet: 810px
- Mobile: 390px

## Motion Presets

| Interaction | Settings |
|-------------|----------|
| Section reveal | whileInView, opacity 0→1, Y 40→0, 0.7s, ease `[0.25, 0.1, 0.25, 1]` |
| Hero load stagger | 0.08s delay between eyebrow / headline / subhead |
| Card hover | translateY -8px, shadow deepen, 0.25s spring |
| Keycap hover | rotateX 8deg, perspective 800px |
| Marquee | translateX -50%, 30s linear loop |
| Testimonial | auto-advance 5s |

## Reference Implementation

The static site at [`../index.html`](../index.html) implements all sections. Use it as a pixel reference when building in Framer, or deploy it directly via any static host.
