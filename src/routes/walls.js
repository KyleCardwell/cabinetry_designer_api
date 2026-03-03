import { Router } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { CreateWallSchema, UpdateWallSchema } from '../models/wall.js';

const router = Router();

// POST /api/walls — create a wall
router.post('/', async (req, res, next) => {
  try {
    const body = CreateWallSchema.parse(req.body);
    const { data, error } = await supabaseAdmin
      .from('cd_walls')
      .insert(body)
      .select()
      .single();

    if (error) throw error;
    res.status(201).json(data);
  } catch (err) { next(err); }
});

// PUT /api/walls/:wallId
router.put('/:wallId', async (req, res, next) => {
  try {
    const body = UpdateWallSchema.parse(req.body);
    const { data, error } = await supabaseAdmin
      .from('cd_walls')
      .update({ ...body, updated_at: new Date().toISOString() })
      .eq('wall_id', req.params.wallId)
      .select()
      .single();

    if (error) throw error;
    if (!data) return res.status(404).json({ error: 'Wall not found' });
    res.json(data);
  } catch (err) { next(err); }
});

// DELETE /api/walls/:wallId
router.delete('/:wallId', async (req, res, next) => {
  try {
    const { error } = await supabaseAdmin
      .from('cd_walls')
      .delete()
      .eq('wall_id', req.params.wallId);

    if (error) throw error;
    res.status(204).end();
  } catch (err) { next(err); }
});

// PUT /api/walls/batch — bulk upsert walls for a room
router.put('/batch', async (req, res, next) => {
  try {
    const { room_id, walls } = req.body;
    if (!room_id || !Array.isArray(walls)) {
      return res.status(400).json({ error: 'room_id and walls[] required' });
    }

    // Delete existing walls for this room, then insert fresh
    await supabaseAdmin.from('cd_walls').delete().eq('room_id', room_id);

    if (walls.length > 0) {
      const rows = walls.map((w, i) => ({
        ...CreateWallSchema.parse({ ...w, room_id }),
        sort_order: i,
      }));

      const { data, error } = await supabaseAdmin
        .from('cd_walls')
        .insert(rows)
        .select();

      if (error) throw error;
      return res.json(data);
    }

    res.json([]);
  } catch (err) { next(err); }
});

export default router;
