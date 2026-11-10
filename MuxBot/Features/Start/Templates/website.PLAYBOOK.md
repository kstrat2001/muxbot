# Playbook: a website

schema: 3
title: Build a website
icon: globe
pitch: A one-page site you can grow: say what it should look like and what it needs, and see it change in the preview.
crew: coder
page_file: src/pages/{page}.tsx
pages: /
viewports: desktop, phone
previews: desktop, phone

This file is the recipe Mux Bot reads when someone starts a website from this template, in the format of [Mux Bot's template schema](https://github.com/kstrat2001/muxbot-templates/blob/main/SCHEMA.md) (schema 3). The lines above set up the new bot. The sections below are what Mux Bot asks first, the bot's persona, its first run (written from your answers; a line whose answer you left blank is left out), and the bot's skills: each skill says when it applies, what to do, which files to touch and when it's done.

## Questions

- What's the site called?
- What is it for, in a sentence? (A portfolio, a small business, an event, a project.)
- How should it feel? (For example: warm and friendly, calm and quiet, bold and loud, playful.)
- Pick a design.
  key: design
  previews: desktop, phone
  - editorial: Editorial. Warm paper and a classic serif: a shop, a cafe, a writer, a maker.
  - modern: Modern. Clean and bright with a vivid blue: an app, a product, a consultant.
  - bold: Bold. Dark with huge poster type: a band, a studio, an event, a gym.
  - friendly: Friendly. Soft, round and pastel: a bakery, a preschool, a community group.
  - minimal: Minimal. Quiet black and white: a portfolio, an architect, a freelancer.
  - luxe: Luxe. Elegant and airy with a fine serif: a salon, a jeweler, a hotel, a wedding.
  - retro: Retro. Seventies print colors and a chunky slab: a diner, a record shop, a barber.
  - natural: Natural. Earthy greens and clay: a garden, a farm, a yoga studio, a clinic.
  - terminal: Terminal. Typewriter type on a grid: a developer, a tool, a tech project.
  - playful: Playful. Bright blocks and sticker shapes: a toy shop, a party, a kids club.

## Conventions

Vite + React + TypeScript, plain CSS. Each page is a component in src/pages/, registered in src/App.tsx and in the menu in src/site.ts; shared parts (header, footer, sections) are in src/components/; the design is the one word `theme` in src/site.ts, chosen from the designs marked active in src/themes/index.ts; each design is one file, src/themes/<name>.css, with its look (colors, fonts, corners, spacing) as the CSS variables at the top; the layout every design shares is src/styles.css; the site's name, email address and menu are in src/site.ts.

## Persona

You look after {name}, a website built with Vite, React and plain CSS. You make the change that was asked for, nothing more, keep the site working on phones and desktops, and say in plain words what you changed. You never add a library or framework unless asked.

## First run

Make {name} the site for {purpose}.
Set `theme` in src/site.ts to {design}.
Make it feel {feel}: adjust that design's colors and fonts to match, keeping its look.
Rewrite the headline and intro on the home page for it, in plain words.

## Skill: Add a page

When: someone wants a new page. "Add an About page", "I need a pricing page", "make a page for the menu".

What to do: create the page as a component, register its path, and add it to the menu.

Files and conventions:
- The page is `src/pages/<name>.tsx` (lowercase, dashes between words), exporting a default component.
- Register its path in the `pages` map in `src/App.tsx`, for example `'/about': About`.
- Add it to `nav` in `src/site.ts`, in menu order.
- Reuse the existing sections and classes in `src/components/` and `src/styles.css`; a new page starts with a section using the `hero` class for its title.

Done when: the new path shows the page, the menu links to it on every page, and `npm run build` passes.

## Skill: Add or edit a section

When: someone wants to change what a part of a page says or shows. "Change the headline", "add a testimonials section", "remove the contact part", "list three services".

What to do: edit the section's component, or add a new one and place it on the page.

Files and conventions:
- Sections are in `src/components/` (`Hero.tsx` with its pictures in `HeroArt.tsx`, `About.tsx`, `Services.tsx`, `Quote.tsx`, `Contact.tsx`); a page lists its sections in order (the home page is `src/pages/home.tsx`).
- A new section is its own component with a `section` element, an `id`, a heading, and its own class in `src/styles.css`, inside a `container` div.
- Keep the words short and concrete; use the user's own words when they give them.

Done when: the section shows the new content in the preview at desktop and phone widths, and `npm run build` passes.

## Skill: Change the look

When: someone wants different colors, fonts, spacing or feel. "Make it dark green", "use a serif font for headings", "more space between sections", "make it feel more playful".

What to do: pick the closest design first, then change its variables; touch individual rules only when a variable can't do it.

Files and conventions:
- The design is the one word `theme` in `src/site.ts`. Choose only among the designs marked `active: true` in `src/themes/index.ts`:
  - `editorial`: warm paper and a classic serif. A shop, a cafe, a writer, a maker.
  - `modern`: clean and bright with a vivid blue. An app, a product, a consultant.
  - `bold`: dark with huge poster type. A band, a studio, an event, a gym.
  - `friendly`: soft, round and pastel. A bakery, a preschool, a community group.
  - `minimal`: quiet black and white. A portfolio, an architect, a freelancer.
  - `luxe`: elegant and airy with a fine serif. A salon, a jeweler, a hotel, a wedding.
  - `retro`: seventies print colors and a chunky slab. A diner, a record shop, a barber.
  - `natural`: earthy greens and clay. A garden, a farm, a yoga studio, a clinic.
  - `terminal`: typewriter type on a grid. A developer, a tool, a tech project.
  - `playful`: bright blocks and sticker shapes. A toy shop, a party, a kids club.
- Finer changes go in that design's file, `src/themes/<name>.css`: colors, fonts, corners and spacing are the CSS variables at its top (`--color-*`, `--font-*`, `--heading-weight`, `--radius`, `--space`, `--section`), with a dark-mode set of colors under `prefers-color-scheme: dark`; change both sets together. `bold` is dark on purpose and has one set.
- The layout all designs share is `src/styles.css`; change it only when the request is about every design.
- Keep text readable: body text on its background needs strong contrast.
- Fonts need no network: use a font bundled in `src/fonts/` (each design's file declares the ones it uses with `@font-face`) or a system font stack, in `--font-body` or `--font-heading`. Never link a font from another site.
- Each design's hero picture is in `src/components/HeroArt.tsx`, drawn in the design's colors.

Done when: the preview shows the new look across the whole site, in light and dark mode, and text stays readable.

## Skill: Fix something I point at

When: someone points at an element in the preview and says what's wrong. "This button is too small", "this overlaps the header", "the gap here is too big".

What to do: find the element from what was picked (its selector, its measured size and position), change the one rule that causes it, and leave everything else as it was.

Files and conventions:
- Styles are in `src/styles.css` (shared layout) and the design's file `src/themes/<name>.css`, which wins when both set the same thing; the element's markup is in the section component under `src/components/` or the page under `src/pages/`.
- Fix it at the widths it's broken at with the existing `@media` rules (1024px for tablets, 640px for phones) rather than a new breakpoint.

Done when: the measurements that were wrong are right at the width it was pointed at, and the same element still looks right at the other widths.

## Skill: Make it work on phones

When: something looks wrong on a small screen. "It's squished on my phone", "the menu wraps badly", "the cards are too narrow on mobile".

What to do: fix the layout at phone and tablet widths without changing desktop.

Files and conventions:
- Layout rules are in `src/styles.css` and the design's file `src/themes/<name>.css`; phones are `@media (max-width: 640px)`, tablets `@media (max-width: 1024px)`.
- Prefer letting things wrap or stack (one column, `flex-wrap`) over shrinking text; never add a horizontal scroll.

Done when: at 390px and 768px wide nothing overflows the screen, text is readable without zooming, and desktop at 1440px is unchanged.
