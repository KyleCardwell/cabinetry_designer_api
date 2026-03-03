/**
 * Build manufacturing reports from resolved room data.
 * These mirror the Python report generators but are used for
 * quick preview without invoking the geometry engine.
 */

/**
 * Shipping list: one row per placed cabinet with key dimensions.
 */
export function buildShippingList(resolvedObjects) {
  return resolvedObjects
    .filter((obj) => obj.object_type.includes('cabinet'))
    .map((obj, idx) => ({
      item: idx + 1,
      type: obj.object_type,
      width: obj.width,
      height: obj.height,
      depth: obj.depth,
      door_count: obj.door_count,
      drawer_count: obj.drawer_count,
      hinge_side: obj.hinge_side,
      object_id: obj.object_id,
    }));
}

/**
 * Door list: one row per door face.
 */
export function buildDoorList(resolvedObjects) {
  const doors = [];
  for (const obj of resolvedObjects) {
    if (!obj.object_type.includes('cabinet') || obj.door_count === 0) continue;

    const doorCount = obj.door_count ?? 0;
    const drawerCount = obj.drawer_count ?? 0;
    const drawerTotalHeight = (obj.drawer_heights ?? []).reduce((s, h) => s + h, 0);

    const overlay = obj.door_overlay ?? 0;
    const reveal = obj.reveal_gap ?? 0;
    const cabinetWidth = obj.width;
    const cabinetHeight = obj.height - (obj.toe_kick_height ?? 0) - drawerTotalHeight;

    const doorWidth = (cabinetWidth + 2 * overlay - (doorCount - 1) * reveal) / doorCount;
    const doorHeight = cabinetHeight + 2 * overlay;

    for (let i = 0; i < doorCount; i++) {
      doors.push({
        object_id: obj.object_id,
        object_type: obj.object_type,
        door_index: i,
        width: Math.round(doorWidth * 10000) / 10000,
        height: Math.round(doorHeight * 10000) / 10000,
        hinge_side: doorCount === 1 ? (obj.hinge_side ?? 'left') : (i === 0 ? 'left' : 'right'),
      });
    }
  }
  return doors;
}

/**
 * Drawer front list: one row per drawer front.
 */
export function buildDrawerFrontList(resolvedObjects) {
  const fronts = [];
  for (const obj of resolvedObjects) {
    if (!obj.drawer_count || obj.drawer_count === 0) continue;

    const overlay = obj.door_overlay ?? 0;
    const reveal = obj.reveal_gap ?? 0;
    const frontWidth = obj.width + 2 * overlay;
    const heights = obj.drawer_heights ?? Array(obj.drawer_count).fill(6);

    for (let i = 0; i < heights.length; i++) {
      fronts.push({
        object_id: obj.object_id,
        drawer_index: i,
        width: Math.round(frontWidth * 10000) / 10000,
        height: heights[i] + 2 * overlay - (i > 0 ? reveal : 0),
      });
    }
  }
  return fronts;
}

/**
 * Drawer box list: one row per drawer box.
 */
export function buildDrawerBoxList(resolvedObjects) {
  const boxes = [];
  for (const obj of resolvedObjects) {
    if (!obj.drawer_count || obj.drawer_count === 0) continue;

    const slideClr = obj.drawer_slide_clearance ?? 0.5;
    const matThick = obj.material_thickness ?? 0.75;
    const boxWidth = obj.width - 2 * slideClr;
    const boxDepth = obj.drawer_box_depth ?? (obj.depth - 3);
    const heights = obj.drawer_heights ?? Array(obj.drawer_count).fill(6);

    for (let i = 0; i < heights.length; i++) {
      const boxHeight = heights[i] - matThick; // front height minus bottom
      boxes.push({
        object_id: obj.object_id,
        drawer_index: i,
        width: Math.round(boxWidth * 10000) / 10000,
        height: Math.round(boxHeight * 10000) / 10000,
        depth: Math.round(boxDepth * 10000) / 10000,
      });
    }
  }
  return boxes;
}
