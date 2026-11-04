# Main UI components

Open `index.html` in a browser for the assembled, responsive workspace preview. The project names and activity are illustrative content.

- `header.html` / `header.css`: brand, workspace context, quick navigation, and keyboard skip link.
- `sidebar.html` / `sidebar.css`: workspace section navigation and supporting context.
- `main-content.html` / `main-content.css`: overview, project summary, expandable projects, and recent activity.
- `components.css`: stylesheet entry point, shared component tokens, and shell layout. Imports the existing design system and all three component stylesheets.

## Integration

Load `components/components.css` once in the document head. The individual HTML files are reusable semantic fragments; insert the header inside `.app-shell`, then put the sidebar and main content inside an `.app-layout` element. See `index.html` for the complete structure. Keep fragment IDs unique and preserve navigation targets when changing content.

The preview contains the same fragments inline so it works directly from disk without JavaScript or a build step. Update its corresponding markup when editing a fragment.

The layout adapts across mobile, tablet, desktop, and wide screen sizes via CSS media queries (see [`../responsive/README.md`](../responsive/README.md) and [`../responsive/`](../responsive/) for standalone layout variations). Colors, type, spacing, borders, and dimensions derive from the existing tokens; dark mode follows the system preference. Project details use native keyboard-accessible disclosure controls. Sidebar links navigate within the page; when adapting them to application routes, set `aria-current="page"` on the current route.
