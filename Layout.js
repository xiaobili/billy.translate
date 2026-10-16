// Where the bubble goes. Pure geometry: no QML, no state, so it can be
// exercised from a plain JS runtime.
//
// Every value here is in logical pixels within one screen's coordinate space.
// Converting the global cursor position into that space is bin/cursor-pos's
// job — this file never sees a global coordinate.

// Places the card near the cursor, kept inside the screen's safe area.
//
//   cursor  {x, y}  cursor position, screen-local logical pixels
//   screen  {w, h}  screen size, logical pixels
//   card    {w, h}  card size, logical pixels
//   gap             distance between the cursor and the card
//   edge            minimum distance between the card and the screen edge
//
// Returns {x, y} for the card's top-left corner.
function place(cursor, screen, card, gap, edge) {
  var x = cursor.x + gap
  var maxX = screen.w - card.w - edge
  if (x > maxX) x = maxX
  if (x < edge) x = edge

  // Below the cursor by default; flip above it when that would overflow. When
  // neither fits (a card taller than the screen) the second clamp wins, which
  // keeps the top edge reachable rather than the bottom.
  var y = cursor.y + gap
  var maxY = screen.h - card.h - edge
  if (y > maxY) y = cursor.y - card.h - gap
  if (y > maxY) y = maxY
  if (y < edge) y = edge

  return { x: x, y: y }
}
