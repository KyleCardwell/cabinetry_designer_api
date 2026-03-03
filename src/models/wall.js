import { z } from 'zod';

const BigIntIdSchema = z.union([
  z.string().regex(/^\d+$/),
  z.number().int().positive(),
]);

export const CreateWallSchema = z.object({
  room_id: BigIntIdSchema,
  x1: z.number(),
  y1: z.number(),
  x2: z.number(),
  y2: z.number(),
  thickness: z.number().positive().optional().default(4.5),
  height: z.number().positive().nullable().optional(),
  sort_order: z.number().int().optional().default(0),
});

export const UpdateWallSchema = z.object({
  x1: z.number().optional(),
  y1: z.number().optional(),
  x2: z.number().optional(),
  y2: z.number().optional(),
  thickness: z.number().positive().optional(),
  height: z.number().positive().nullable().optional(),
  sort_order: z.number().int().optional(),
});
