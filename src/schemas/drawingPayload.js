import { z } from 'zod';

export const drawingPayloadSchema = z.object({
  payloadVersion: z.literal(1),
  units: z.literal('in'),
  room: z.object({ id: z.string().min(1), name: z.string() }).passthrough(),
  elevations: z.array(z.object({}).passthrough()),
}).passthrough();
