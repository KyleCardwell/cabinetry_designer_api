import { z } from 'zod';

const BigIntIdSchema = z.union([
  z.string().regex(/^\d+$/),
  z.number().int().positive(),
]);

export const CreateRoomSchema = z.object({
  project_id: BigIntIdSchema,
  name: z.string().min(1).max(255),
  floor_to_ceiling: z.number().positive().optional(),
  default_params: z.record(z.unknown()).optional().default({}),
  sort_order: z.number().int().optional().default(0),
});

export const UpdateRoomSchema = z.object({
  name: z.string().min(1).max(255).optional(),
  floor_to_ceiling: z.number().positive().nullable().optional(),
  default_params: z.record(z.unknown()).optional(),
  sort_order: z.number().int().optional(),
});
