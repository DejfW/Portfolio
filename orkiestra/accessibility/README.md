# Accessibility Features (ARIA, Keyboard Navigation & Semantic HTML)

Accessible HTML templates, WAI-ARIA 1.2 widgets, keyboard navigation controllers, and WCAG 2.1 AA stylesheets for the Orkiestra UI. Built strictly on the design tokens in [`../styles/variables.css`](../styles/variables.css), [`../styles/base.css`](../styles/base.css), [`../components/components.css`](../components/components.css), and [`../responsive/responsive.css`](../responsive/responsive.css).

## Files in `accessibility/`

- [`index.html`](./index.html): **Main Accessibility & WAI-ARIA Hub** — multi-target skip links, `<form role="search">` landmark, breadcrumb navigation, WAI-ARIA tabs (`role="tablist"`, `role="tab"`, `role="tabpanel"`), sortable accessible task table (`aria-sort`), polite/assertive live regions (`role="status"`, `role="alert"`, `role="log"`), custom ARIA controls (`role="radiogroup"`, `role="spinbutton"`, `role="switch"`, `role="menu"`), and focus-trapped `<dialog>` modals.
- [`forms-and-dialogs.html`](./forms-and-dialogs.html): **Accessible Forms, Auth & Modal Dialogs** — accessible implementations of the Sign-in screen (`01-sign-in.svg`), New Run configuration dialog (`05-new-run-modal.svg`), and Task action states (`04-task-detail.svg`) with `<fieldset>`, `<legend>`, `<label for>`, password show/hide toggle (`aria-pressed`), `aria-invalid`, `aria-describedby`, `aria-disabled`, and focusable `role="alert"` error summaries.
- [`landmarks-and-navigation.html`](./landmarks-and-navigation.html): **Semantic Landmarks & Live Agent Output** — semantic HTML5 landmark architecture, keyboard roving navigation across master-detail task lists, live agent streaming log (`role="log" aria-live="polite" aria-relevant="additions"`), and changed-files summary.
- [`accessibility.css`](./accessibility.css): **Accessibility Stylesheet** — `.sr-only` / `.sr-only-focusable` screen-reader utilities, multi-target `.skip-links`, high-visibility `:focus-visible` rings, ARIA widget states (`[aria-selected="true"]`, `[aria-checked="true"]`, `[aria-pressed="true"]`, `[aria-invalid="true"]`, `[aria-disabled="true"]`), and `@media` queries for `prefers-reduced-motion`, `prefers-contrast: more`, `forced-colors: active`, and `prefers-color-scheme: dark`.
- [`keyboard-navigation.js`](./keyboard-navigation.js): **Keyboard Navigation & ARIA Controller** — zero-dependency script implementing WAI-ARIA Authoring Practices (APG) roving `tabindex`, modal focus trapping and restoration, sortable table headers, accessible form validation, and global keyboard shortcuts.

## Keyboard Navigation & Shortcuts

| Key / Shortcut | Context | Behavior |
|---|---|---|
| `Tab` / `Shift+Tab` | Global | Moves focus sequentially across interactive landmarks and controls with visible `:focus-visible` rings |
| `/` | Global (outside inputs) | Focuses the `<form role="search">` input (`#workspace-search-input`) |
| `?` (`Shift+/`) | Global (outside inputs) | Opens the Keyboard Navigation Shortcuts modal dialog (`#shortcuts-dialog`) |
| `Alt+N` | Global | Opens the New Run modal dialog (`#new-run-dialog`) and focuses the first field |
| `Alt+1` … `Alt+4` | Run Hub | Switches directly between tabs in `[role="tablist"]` |
| `←` `→` `↑` `↓` `Home` `End` | `[role="tablist"]`, `[role="radiogroup"]`, `[role="toolbar"]`, `[data-roving-nav]` | Roving `tabindex` navigation across tabs, agent radio cards, toolbars, and navigation lists |
| `↑` `↓` `Home` `End` | `[role="spinbutton"]` & `[role="menu"]` | Increments/decrements stepper values or navigates dropdown menu items |
| `Space` / `Enter` | `[role="switch"]`, `[aria-pressed]`, `th[aria-sort] button`, `<summary>` | Toggles switch/button state, sorts table column, or expands disclosure card |
| `Escape` | `<dialog>` / `[role="menu"]` | Closes the active modal dialog or popup menu and restores focus to the trigger button |

## Semantic HTML & WAI-ARIA Summary

- **Landmarks:** `<header>`, `<nav aria-label="...">` (distinct labels for Skip links, Accessibility views, Breadcrumb, Workspace sections, and Footer links), `<form role="search">`, `<main id="main-content" tabindex="-1">`, `<aside aria-labelledby="...">`, `<section aria-labelledby="...">`, and `<footer class="app-footer">`.
- **Live Regions:** `#a11y-live-announcer` (`role="status" aria-live="polite" aria-atomic="true"`), `#a11y-alert-announcer` (`role="alert" aria-live="assertive" aria-atomic="true"`), and `#agent-log-output` (`role="log" aria-live="polite" aria-atomic="false" aria-relevant="additions"`).
- **Non-Color Status Signals:** Every status badge (`.status-pill`) pairs semantic color tokens with an icon symbol (`✓`, `●`, `!`, `○` marked `aria-hidden="true"`) and explicit text labels.
- **Touch & Pointer Targets:** All buttons, inputs, selects, tabs, radio cards, steppers, and links enforce `min-block-size: var(--component-target-size)` (`48px`), exceeding the WCAG 2.5.5 / 2.5.8 `44×44px` minimum.
