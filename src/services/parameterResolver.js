import { SYSTEM_DEFAULTS } from '../config/defaults.js';

/**
 * Resolve a single parameter through the fallback chain:
 *   object.params.{key} → object.{key} → room.default_params → project.default_params → team_defaults → system
 */
export function resolveParam(key, object, room, project, teamDefaults) {
  return object?.params?.[key]
    ?? object?.[key]
    ?? room?.default_params?.[key]
    ?? project?.default_params?.[key]
    ?? teamDefaults?.default_params?.[key]
    ?? SYSTEM_DEFAULTS[key];
}

/**
 * Type-specific dimension defaults.
 * Maps object_type to { height_key, depth_key } in SYSTEM_DEFAULTS.
 */
const TYPE_DIMENSION_MAP = {
  base_cabinet:  { height: 'base_cabinet_height',  depth: 'base_cabinet_depth' },
  wall_cabinet:  { height: 'wall_cabinet_height',  depth: 'wall_cabinet_depth' },
  tall_cabinet:  { height: 'tall_cabinet_height',  depth: 'tall_cabinet_depth' },
};

/**
 * Fully resolve all parameters for a single placed object.
 * Returns a flat object with every param filled in — no nulls.
 */
export function resolveObject(object, room, project, teamDefaults) {
  const r = (key) => resolveParam(key, object, room, project, teamDefaults);

  const typeMap = TYPE_DIMENSION_MAP[object.object_type];

  const resolved = {
    object_id: object.object_id,
    object_type: object.object_type,
    wall_id: object.wall_id,
    x: object.x,
    y: object.y,
    z: object.z ?? 0,
    rotation: object.rotation ?? 0,

    // Dimensions: object-level → type-specific system default → generic default
    width:  object.width  ?? r('default_width'),
    height: object.height ?? (typeMap ? r(typeMap.height) : r('base_cabinet_height')),
    depth:  object.depth  ?? (typeMap ? r(typeMap.depth)  : r('base_cabinet_depth')),

    // Construction
    material_thickness:     r('material_thickness'),
    back_material_thickness: r('back_material_thickness'),
    toe_kick_height:        r('toe_kick_height'),
    toe_kick_depth:         r('toe_kick_depth'),
    has_stretchers:         r('has_stretchers'),

    // Face
    door_count:    r('door_count'),
    drawer_count:  r('drawer_count'),
    door_overlay:  r('door_overlay'),
    reveal_gap:    r('reveal_gap'),
    hinge_side:    r('hinge_side'),

    // Drawers
    drawer_slide_clearance: r('drawer_slide_clearance'),
    drawer_heights: object.params?.drawer_heights ?? null,
    drawer_box_depth: object.params?.drawer_box_depth ?? null,

    // Shelves
    shelf_count:   r('shelf_count'),
    shelf_setback: r('shelf_setback'),
  };

  return resolved;
}

/**
 * Resolve all objects in a room. Returns the full room payload
 * ready for the geometry engine.
 */
export function resolveRoom(room, walls, objects, project, teamDefaults) {
  const resolvedObjects = objects.map((obj) => resolveObject(obj, room, project, teamDefaults));

  return {
    room_id: room.room_id,
    name: room.name,
    floor_to_ceiling: room.floor_to_ceiling ?? resolveParam('floor_to_ceiling', null, room, project, teamDefaults),
    walls: walls.map((w) => ({
      wall_id: w.wall_id,
      x1: w.x1, y1: w.y1,
      x2: w.x2, y2: w.y2,
      thickness: w.thickness ?? resolveParam('wall_thickness', null, room, project, teamDefaults),
      height: w.height ?? room.floor_to_ceiling ?? resolveParam('floor_to_ceiling', null, room, project, teamDefaults),
    })),
    objects: resolvedObjects,
  };
}
