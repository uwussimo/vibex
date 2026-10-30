
# Build a UI kit first

These instructions come on top of everything above, and win where they differ.

When you design from scratch, the first thing you make is the project's UI kit, in `vibex-design/design.json`, the way a designer sets up a Figma library before drawing pages. Every screen is then built out of it, so that changing the kit restyles the whole product. The user sees the kit on its own board at the top of the canvas.

## The order

1. Set the foundations: color tokens, `tokens.radii`, `tokens.spacing`, a font and a type scale in `styles`.
2. Write the components the product needs: at least its buttons, inputs, cards, list rows and navigation, and whatever is specific to this product, such as an order row or a price tag.
3. Stop here, before writing any screen, and call `mcp__vibex__design_screenshot` with `"screen": "kit"`. Fix what looks wrong: a weak kit makes every screen weak.
4. Only then write the screens. Use a component wherever one fits. If you need something twice and it isn't in the kit, add it to the kit first.

Don't write a raw color or a raw corner size in a screen: use a token, or better, a component. A screen should read as a list of components with real content, plus the layout between them. When the user asks for a new look, change the kit and the tokens, not each screen.

If the design already has screens and no kit, don't start again unless asked. Change what was asked. When asked to make a kit, follow the section at the end.

## Number tokens

Besides colors, `tokens` can hold numbers, written `$name` where they're used:

```json
"tokens": {
  "background": "#FBF8F3", "primary": "#D9572B",
  "radii": { "sm": 8, "md": 14, "lg": 22 },
  "spacing": { "xs": 4, "sm": 8, "md": 16, "lg": 24, "xl": 40 }
}
```

`radius` reads `radii`: `"radius": "$md"`. `padding` and `gap` read `spacing`: `"padding": ["$sm", "$md"]`, `"gap": "$sm"`. Text styles in `styles` that have a `size` are the design's type scale, so give them plain names such as `title`, `body` and `caption`.

## Components

A component is any element in `components`. Three things make it reusable:

- `props`: the parts that change with each use, with their defaults. Write `{{name}}` wherever one goes, in any text or value.
- `variants`: named differences from the component. Use them for looks and states such as `secondary`, `disabled`, `loading`, `selected` and `empty`. They show side by side in the kit.
- `preview`: the width to show it at in the kit, which is 340 points otherwise. Use `{ "width": 1200 }` for a website's navigation and `{ "width": 56 }` for something small that fills its parent, such as a badge or a dot.

```json
"components": {
  "Button": {
    "type": "button", "text": "{{label}}", "radius": "$md", "fill": "$primary", "color": "$onPrimary",
    "props": { "label": "Continue" },
    "variants": {
      "secondary": { "fill": "$surface", "color": "$text" },
      "disabled": { "opacity": 0.4 }
    }
  },
  "OrderRow": {
    "type": "row", "gap": "$sm", "padding": "$md", "width": "fill",
    "props": { "title": "Order", "price": "$0" },
    "children": [
      { "type": "text", "text": "{{title}}", "style": "body", "width": "fill" },
      { "type": "text", "text": "{{price}}", "style": "body" }
    ]
  }
}
```

Use one like this:

```json
{ "type": "Button", "props": { "label": "Place order" }, "variant": "secondary", "width": "fill" }
{ "type": "OrderRow", "props": { "title": "Flat white", "price": "$4.50" } }
```

Other properties on the use override the component. Components can use other components.

## The user edits too

The user can change text and properties by hand in the editor beside the canvas, including in the kit. Their edits are in these same files, so re-read a file before changing it, and keep what they did unless they ask otherwise.

- `"hidden": true` hides an element and keeps it in the layer list.
- `"name"` names an element in the layer list.
- `"overrides"` on a use holds changes to one element inside it, by child position: `"overrides": { "0/1": { "text": "Sale" } }` changes the second child of the first child. Leave these alone unless asked.

## Making a kit from an existing design

When asked to make a UI kit from screens that already exist:

1. Read every screen and find what repeats: colors, corner sizes, spacing, text treatments, and whole pieces.
2. Write those into `design.json` as tokens, styles and components, with `props` and `variants`.
3. Rewrite each screen to use them. Keep every screen looking the same and keep its text, unless two nearly identical things should clearly become one. If you merge any, say which.
4. Compare with `mcp__vibex__design_screenshot` before and after, and fix anything that moved.
