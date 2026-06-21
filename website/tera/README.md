# Tera Marketing Site

Static reference implementation of the Tera browser marketing site (Midu structure, earth/nature aesthetic).

## Preview

```bash
python3 -m http.server 8080
```

Open http://localhost:8080

## Structure

```
tera/
├── index.html          # Main landing page
├── privacy.html        # Privacy policy
├── css/styles.css      # Full stylesheet
├── js/main.js          # Nav, parallax, carousels, accordions
├── design/             # Tokens + Unsplash manifest
├── assets/             # SVG wordmark, keycaps, mockups, OG
├── framer/             # Framer import guide
└── assets/screenshots/ # Replace with live app PNGs
```

## Deploy

Upload this directory to Vercel/Netlify, or recreate in Framer using `framer/BUILD_GUIDE.md`.

Documentation: [docs/TERA_WEBSITE.md](../../docs/TERA_WEBSITE.md)
