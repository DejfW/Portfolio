# Portfolio site

A static portfolio (plain HTML, CSS and ES modules, no build step, no dependencies) in the dark "n8n" style described in [DESIGN.md](DESIGN.md). Every project is a folder with a `project.json`; the pages render it in the browser.

## Run locally

```bash
node scripts/serve-portfolio.mjs        # http://localhost:8090
node scripts/validate-portfolio.mjs     # checks site.json, the manifest, every project and its media files
node --test portfolio/test/             # unit tests and style-rule tests
```

## Edit your profile and CV

`portfolio/site.json` drives the hero, the About section, the nav and the footer:

| Field | Meaning |
|---|---|
| `name`, `headline` | Brand name in the nav and the hero title |
| `about` | `{ "title", "paragraphs": [...] }` — the bio (replace the `TODO(author)` text) |
| `highlights` | Optional `[{ "title", "text" }]` — tiles next to the bio |
| `skills` | Optional `[{ "group", "items": [...] }]` — grouped pills |
| `links` | `[{ "label", "url" }]` — GitHub, LinkedIn, `mailto:` (http, https and mailto only) |
| `cv` | Optional `{ "label": "Download CV", "url": "assets/cv.pdf" }`. Put the PDF at `portfolio/assets/cv.pdf` first; without this field no CV button is shown |

## Add a project

1. Copy `projects/_template` to `projects/<slug>` (lowercase letters, digits and dashes).
2. Fill in `project.json` and set `"slug"` to the folder name. Delete the blocks you do not need.
3. Put images and videos in `projects/<slug>/media/`.
4. Add the slug to `projects/index.json` (the order there is the order on the page).
5. Run `node scripts/validate-portfolio.mjs`. It fails on bad links, unsafe or missing media paths and invalid blocks.

A project with `"status": "planned"` needs only `slug`, `title`, `status` and `tagline` and shows up as a "Coming soon" card.

## Block types

Each entry in `sections` is `{ "type": ..., "title"?: ..., ... }`:

| Type | Fields |
|---|---|
| `prose` | `paragraphs: string[]` |
| `list` | `items: [{ title, text }]` (cards, good for decisions) |
| `table` | `columns: string[]`, `rows: string[][]` |
| `gallery` | `items: [{ type: "image", src, alt, caption? } \| { type: "video", src, poster?, caption? }]`; an empty list shows a placeholder |
| `diagram` | `src`, `alt`, `caption?` (click to enlarge) |
| `chart` | `unit?`, `bars: [{ label, value }]` |
| `graph` | `nodes: [{ id, label, layer, kind? }]`, `edges: [{ from, to }]`; `layer` is the column, edges must go to a later layer; `kind` is `channel`, `workflow`, `db`, `ai` or `output` |

## Recordings and screenshots

Add them to a `gallery` block:

```json
{ "type": "gallery", "title": "Demo", "items": [
  { "type": "image", "src": "media/dashboard.webp", "alt": "What the screenshot shows", "caption": "Optional" },
  { "type": "video", "src": "media/demo.mp4", "poster": "media/demo-poster.webp" }
] }
```

Recommended: `mp4` (H.264) up to about 20 MB, screenshots as `webp` or `png` around 1600 px wide, and always an `alt` text for images. Videos never autoplay. Paths are relative to the project folder; `..`, absolute paths and URLs are rejected.

## Deploy

The contents of `portfolio/` are plain static files, so they work on GitHub Pages, Cloudflare Pages or any static host. Publishing is your decision; nothing here deploys it.
