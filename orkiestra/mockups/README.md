# Visual design mockups

High-fidelity mockups of the key orkiestrA screens, as SVG files. They are built from the tokens in [`../design-system.md`](../design-system.md) and [`../styles/variables.css`](../styles/variables.css). Open them in a browser, or drag them into Figma, where each element imports as an editable vector layer.

| # | Screen | File | Size |
|---|---|---|---|
| 1 | Sign in | [`01-sign-in.svg`](01-sign-in.svg) | 1440 × 960 |
| 2 | Dashboard | [`02-dashboard.svg`](02-dashboard.svg) | 1440 × 960 |
| 3 | Run detail (task list) | [`03-run-detail.svg`](03-run-detail.svg) | 1440 × 960 |
| 4 | Task detail (live agent output) | [`04-task-detail.svg`](04-task-detail.svg) | 1440 × 960 |
| 5 | New run dialog | [`05-new-run-modal.svg`](05-new-run-modal.svg) | 1440 × 960 |
| 6 | Dashboard, mobile | [`06-mobile-dashboard.svg`](06-mobile-dashboard.svg) | 390 × 844 |

## Main user flow

Sign in (1) → Dashboard (2) shows run health and anything waiting for review → start a run from **New run** (5) → follow it in Run detail (3) → open a task to watch the agent's output and approve the result (4). The mobile dashboard (6) covers checking in and reviewing while away from a desk.

## Layout

- **Desktop shell:** a 240px sidebar for navigation and a 64px top bar with search, notifications, **New run** and the account menu. The content area starts 32px (`--space-6`) from the sidebar and runs to 32px from the right edge.
- **Grid:** 24px (`--space-5`) between cards. Card padding is 24px, and every value is on the 4px scale.
- **Mobile:** 16px side gutters, a 2 × 2 KPI grid, stacked run cards and a bottom tab bar in place of the sidebar.

## How the design system is applied

- **Color:** primary `#4f46e5` is used for actions, the active nav item, links and chart bars. Text uses `--color-text` / `--color-text-muted`. Surfaces and borders use `--color-surface` / `--color-border`.
- **Status:** success = Done, info = Running, warning = Needs review, neutral = Queued, danger = destructive actions. Every status badge pairs its color with an icon (✓, ●, !, ○) and a text label, so color is never the only signal.
- **Type:** page titles are 32px bold, card titles 20px medium, body text 16px, and table and secondary text 14px/12px. IDs, branches, file paths and agent names use `--font-mono`.
- **Touch targets:** all buttons, inputs, selects and steppers are 44px tall.
- **Radius and elevation:** inputs use 4px, cards and buttons 8px, and the dialog 16px. Cards use `--shadow-sm`; the sign-in card and the dialog use `--shadow-md`.
- **Focus:** the sign-in password field shows the focus style, a 2px `--color-focus` border with a `--color-primary-100` ring.

## Notes for the design system

- **Missing feedback tints.** The system only defines solid feedback colors. These mockups therefore use outlined status pills (colored border and text on white) instead of tinted fills. If tinted badges are wanted, add tokens such as `--color-success-bg`.
- **Disabled state is undefined.** The disabled **Approve and merge** button uses `--color-neutral-100` as its fill and muted text. This should become a documented token or pattern.
- **Dark mode.** The mockups show the light theme only. Dark mode follows from overriding the semantic tokens, as `variables.css` already does.
- **PNG exports.** No rasterizer was available where these were made. To export PNGs, run `rsvg-convert -w 2880 02-dashboard.svg -o 02-dashboard@2x.png`, or export from Figma after importing.

All data shown (runs, tasks, timings, initials) is placeholder content.
