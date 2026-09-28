# Up website

A static site: no build step. Serve this folder and open `index.html`.

```sh
npx serve website
```

## Where it comes from

- `app.js` is the Claude Design file "Up Only Website" (project `3cfd32a1-d455-4053-bed8-ad248e3d5760`), ported from the design tool's format to React with [htm](https://github.com/developit/htm). Markup and inline styles are kept as the design wrote them, so a design change can be copied across section by section.
- `ds/ds-bundle.js` is the generated build of the "Up Only design system" project, unmodified. `ds/tokens.css` is its tokens in one file.
- `vendor/` holds React 18.3.1, React DOM 18.3.1 and htm 3.1.1, served from here so the page makes no third-party requests.
- `assets/icons/` are Lucide icons (ISC licence), which the design system uses in place of SF Symbols.
- Bank and coin logos are copied from the app's asset catalog.

The SF Pro font files from the design system are not included: Apple's licence does not allow serving them. The type stack falls back to `-apple-system`, which is SF Pro on Apple devices.

## Not wired up yet

- **Download for Mac** buttons have no link.
- **The iPhone waitlist** only shows the confirmation. No email is stored or sent.
- **Footer links** point at sections of this page, not real pages.
- **The app icon** is the dark icon. The design uses a green one (`assets/up-icon-green.png` in the design project) that was too large to fetch through the design connection.
