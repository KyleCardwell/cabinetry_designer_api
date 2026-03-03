import { z } from 'zod';

const OBJECT_TYPES = [
  'base_cabinet', 'wall_cabinet', 'tall_cabinet',
  'appliance', 'filler', 'shelf', 'panel',
];

const BigIntIdSchema = z.union([
  z.string().regex(/^\d+$/),
  z.number().int().positive(),
]);

export const CreatePlacedObjectSchema = z.object({
  room_id: BigIntIdSchema,
  wall_id: BigIntIdSchema.nullable().optional(),
  object_type: z.enum(OBJECT_TYPES),
  catalog_id: z.string().max(100).nullable().optional(),
  x: z.number().default(0),
  y: z.number().default(0),
  z: z.number().default(0),
  rotation: z.number().default(0),
  width: z.number().positive().nullable().optional(),
  height: z.number().positive().nullable().optional(),
  depth: z.number().positive().nullable().optional(),
  params: z.record(z.unknown()).optional().default({}),
  sort_order: z.number().int().optional().default(0),
});

export const UpdatePlacedObjectSchema = z.object({
  wall_id: BigIntIdSchema.nullable().optional(),
  object_type: z.enum(OBJECT_TYPES).optional(),
  catalog_id: z.string().max(100).nullable().optional(),
  x: z.number().optional(),
  y: z.number().optional(),
  z: z.number().optional(),
  rotation: z.number().optional(),
  width: z.number().positive().nullable().optional(),
  height: z.number().positive().nullable().optional(),
  depth: z.number().positive().nullable().optional(),
  params: z.record(z.unknown()).optional(),
  sort_order: z.number().int().optional(),
});
