import { z } from 'zod';

export const CreateProjectSchema = z.object({
  team_id: z.string().uuid(),
  name: z.string().min(1).max(255),
  client_name: z.string().max(255).optional(),
  address: z.string().max(500).optional(),
  default_params: z.record(z.unknown()).optional().default({}),
});

export const UpdateProjectSchema = z.object({
  name: z.string().min(1).max(255).optional(),
  client_name: z.string().max(255).nullable().optional(),
  address: z.string().max(500).nullable().optional(),
  default_params: z.record(z.unknown()).optional(),
});
