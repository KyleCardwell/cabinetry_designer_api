/** "G1 Euro kitchen" → "g1-euro-kitchen.zip" (SPEC-40); same rule as the designer's drawingZipName. */
export function drawingZipName(roomName) {
  const name = roomName.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  return `${name || 'room'}.zip`;
}
