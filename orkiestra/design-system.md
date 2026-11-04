# Design System

Tokens live in `styles/variables.css` (CSS custom properties). `styles/base.css` applies them to base elements. Always use tokens, never hard-coded values.

```html
<link rel="stylesheet" href="styles/base.css">
```

## Color

| Role | Token | Value |
|---|---|---|
| Primary | `--color-primary-600` | #4f46e5 |
| Primary (hover) | `--color-primary-700` | #4338ca |
| Primary (tint) | `--color-primary-50` | #eef2ff |
| Background | `--color-bg` | #ffffff (dark: #0f172a) |
| Surface | `--color-surface` | #f8fafc (dark: #1e293b) |
| Border | `--color-border` | #e2e8f0 |
| Text | `--color-text` | #0f172a |
| Muted text | `--color-text-muted` | #64748b |
| Success | `--color-success` | #15803d |
| Warning | `--color-warning` | #b45309 |
| Danger | `--color-danger` | #b91c1c |
| Info | `--color-info` | #0369a1 |

Guidelines:
- Use semantic tokens (`--color-text`, `--color-bg`) in components; use raw scale tokens only to define semantics.
- Text must meet WCAG AA contrast (4.5:1 body, 3:1 large text). Don't convey meaning by color alone.
- Dark mode is automatic via `prefers-color-scheme`, by overriding semantic tokens only.

## Typography

- Sans: `--font-sans` (Inter, system fallbacks). Mono: `--font-mono`.
- Scale: xs 12px, sm 14px, base 16px, lg 20px, xl 24px, 2xl 32px, 3xl 40px (`--font-size-*`).
- Weights: regular 400, medium 500, bold 700.
- Line height: tight 1.2 (headings), base 1.5 (body), loose 1.75 (long-form).
- Body text is 16px minimum; keep line length to about 60 to 75 characters.

| Element | Size | Weight |
|---|---|---|
| h1 | 3xl | bold |
| h2 | 2xl | bold |
| h3 | xl | medium |
| Body | base | regular |
| Caption | sm / xs | regular |

## Spacing

4px base unit; use only the scale (`--space-*`):

| Token | Value |
|---|---|
| `--space-1` | 4px |
| `--space-2` | 8px |
| `--space-3` | 12px |
| `--space-4` | 16px |
| `--space-5` | 24px |
| `--space-6` | 32px |
| `--space-7` | 48px |
| `--space-8` | 64px |

Guidelines:
- Related items: `--space-2` to `--space-3`; between groups: `--space-4` to `--space-5`; between sections: `--space-7` or more.
- Component padding: `--space-3` / `--space-4`.
- Touch targets are at least 44×44px.

## Radius and elevation

`--radius-sm` 4px (inputs), `--radius-md` 8px (cards, buttons), `--radius-lg` 16px (modals), `--radius-full` (pills). Shadows: `--shadow-sm` for cards, `--shadow-md` for popovers and modals.
