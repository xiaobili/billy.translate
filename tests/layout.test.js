const { load, check, report } = require("./run")

const Layout = load("Layout.js")

// A 2560x1080 screen, a 420x200 card, matching the machine this targets.
const SCREEN = { w: 2560, h: 1080 }
const CARD = { w: 420, h: 200 }
const GAP = 12
const EDGE = 8

// Middle of the screen: below and to the right of the cursor.
check("places below-right when there is room",
  Layout.place({ x: 800, y: 400 }, SCREEN, CARD, GAP, EDGE),
  { x: 812, y: 412 })

// Near the bottom edge: must flip above the cursor.
check("flips above when it would overflow the bottom",
  Layout.place({ x: 800, y: 1003 }, SCREEN, CARD, GAP, EDGE),
  { x: 812, y: 791 })

// Near the right edge: must clamp to the safe area.
check("clamps to the right edge",
  Layout.place({ x: 2550, y: 400 }, SCREEN, CARD, GAP, EDGE),
  { x: 2132, y: 412 })

// Cursor at the origin. The gap alone (12) already clears the edge floor (8),
// so the card lands at the gap offset and the edge clamp never fires. (This
// case originally expected {8,8}; that expectation was wrong, not the code.)
check("a cursor at the origin lands at the gap offset",
  Layout.place({ x: 0, y: 0 }, SCREEN, CARD, GAP, EDGE),
  { x: 12, y: 12 })

// A card taller than the screen cannot fit either way; the top edge is the
// only position that stays reachable.
check("clamps a card taller than the screen",
  Layout.place({ x: 800, y: 600 }, { w: 2560, h: 400 }, { w: 420, h: 900 }, GAP, EDGE),
  { x: 812, y: 8 })

// Bottom-right corner: x clamps to the right margin, and y flips above the
// cursor. That flip is already legal (card bottom 1068 <= 1080 - 8), so the
// second clamp does not fire — only one axis clamps. (This case originally
// expected {2132,8}; that expectation was wrong, not the code.)
check("clamps to the right margin and flips above near the bottom",
  Layout.place({ x: 2560, y: 1080 }, SCREEN, CARD, GAP, EDGE),
  { x: 2132, y: 868 })

report()
