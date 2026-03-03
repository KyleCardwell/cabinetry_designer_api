/**
 * System-level parameter defaults — the bottom of the fallback chain.
 * object.params → room.default_params → project.default_params → team_defaults → THIS
 */
export const SYSTEM_DEFAULTS = {
  // Cabinet construction
  material_thickness: 0.75,
  back_material_thickness: 0.25,
  toe_kick_height: 4,
  toe_kick_depth: 3,
  has_stretchers: true,

  // Face
  door_count: 2,
  drawer_count: 0,
  door_overlay: 0.5,
  reveal_gap: 0.125,
  hinge_side: 'left',

  // Drawers
  drawer_slide_clearance: 0.5,

  // Shelves
  shelf_count: 1,
  shelf_setback: 0.125,

  // Dimensions by type
  base_cabinet_height: 34.5,
  base_cabinet_depth: 24,
  wall_cabinet_height: 30,
  wall_cabinet_depth: 12,
  tall_cabinet_height: 84,
  tall_cabinet_depth: 24,
  default_width: 24,

  // Room
  floor_to_ceiling: 96,
  wall_thickness: 4.5,
};
