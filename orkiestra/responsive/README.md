# Responsive Design & Layout Variations

Responsive stylesheets, `@media` queries, and layout variations for the Orkiestra UI. Built strictly on the tokens in [`../styles/variables.css`](../styles/variables.css), [`../styles/base.css`](../styles/base.css), and [`../components/components.css`](../components/components.css).

## Files in `responsive/`

- [`responsive.css`](./responsive.css): Responsive layout tokens, viewport and preference `@media` queries, adaptive components (bottom tab bar, horizontal sub-navigation, responsive table-to-card list, asymmetric workspace split, and master-detail split pane), and layout variation classes.
- [`index.html`](./index.html): Interactive responsive workspace overview and layout variation showcase with a live CSS breakpoint indicator.
- [`mobile.html`](./mobile.html): **Mobile layout variation** (`.layout-mobile`) — compact header, 16px (`--space-4`) gutters, 2×2 KPI summary grid, "Needs your attention" callout card, stacked run/project cards, and a fixed bottom tab bar (`.app-tabbar`) in place of the sidebar.
- [`tablet.html`](./tablet.html): **Tablet layout variation** (`.layout-tablet`) — 24px (`--space-5`) gutters, horizontal sub-navigation bar (`.app-subnav`) replacing the wide vertical sidebar, and 2-column balanced grids (`.tablet-grid-2col`) for projects and activity.
- [`desktop.html`](./desktop.html): **Desktop layout variation** (`.layout-desktop`) — 32px (`--space-6`) gutters, persistent 240px left sidebar, 64px top bar, 4-column KPI strip (`.kpi-grid--4col`), 2:1 asymmetric workspace split (`.workspace-split`), and a responsive data table (`.run-table`).
- [`split-detail.html`](./split-detail.html): **Master-detail split variation** (`.layout-split-detail`) — sticky 1:2 master-detail split pane (`.split-pane`) pairing the run task list with live agent output on desktop (`>= 1024px`) and stacking vertically on tablet and mobile.

## Breakpoints & Media Queries

| Breakpoint Tier | Media Query | Gutters | Navigation Pattern | Grid Behavior |
|---|---|---|---|---|
| **Narrow Mobile** | `@media (max-width: 360px)` | `16px` (`--space-4`) | Bottom tab bar (2×2 grid) or compact top pills | 1-column KPI and project stack; full-width header actions |
| **Small Mobile** | `@media (max-width: 480px)` | `16px` (`--space-4`) | Bottom tab bar or compact top pills; secondary sidebar note hidden | 2×2 KPI grid; single-column cards; scaled headings (`h1` `2xl`, `h2` `xl`, `h3` `lg`) |
| **Mobile** | `@media (max-width: 767px)` | `16px` (`--space-4`) | Fixed bottom tab bar (`.app-tabbar`) or horizontal top pill grid | 2×2 KPI grid; `.run-table` rows convert to stacked cards with `data-label` headers |
| **Tablet** | `@media (min-width: 768px) and (max-width: 1023px)` | `24px` (`--space-5`) | Horizontal sub-navigation bar (`.app-subnav`) or 3-column top nav | 3-column stats, 2-column project and activity grids (`.tablet-grid-2col`) |
| **Desktop** | `@media (min-width: 1024px)` | `32px` (`--space-6`) | Persistent 240px left sidebar (`--component-sidebar-width`), 64px top header | 4-column KPI strip, 2:1 `.workspace-split`, 1:2 `.split-pane` |
| **Wide Desktop** | `@media (min-width: 1280px)` | `32px` (`--space-6`) | Persistent 256px left sidebar | Multi-column expandable project cards and 2-column activity timeline |

## User Preference & Environment Media Queries

- `@media (prefers-color-scheme: dark)`: Automatic dark theme via semantic color tokens in `styles/variables.css`.
- `@media (prefers-reduced-motion: no-preference)` / `reduce`: Enables smooth anchor scrolling only when motion is allowed, and zeroes transition/animation durations when reduced motion is requested.
- `@media (prefers-contrast: more)`: Doubles `--component-border-width` for stronger visual boundaries.
- `@media (hover: none) and (pointer: coarse)`: Increases touch target spacing on touch screens while maintaining `>= 44×44px` (`--component-target-size: 48px`) interactive targets.
- `@media print`: Hides navigation chrome (`.app-sidebar`, `.app-tabbar`, `.app-subnav`, `.variation-switcher`, `.skip-link`) and formats cards for clean multi-page printing.
