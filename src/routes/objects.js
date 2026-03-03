import { Router } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { CreatePlacedObjectSchema, UpdatePlacedObjectSchema } from '../models/placedObject.js';

const router = Router();

// POST /api/objects
router.post('/', async (req, res, next) => {
  try {
    const body = CreatePlacedObjectSchema.parse(req.body);
    const { data, error } = await supabaseAdmin
      .from('cd_placed_objects')
      .insert(body)
      .select()
      .single();

    if (error) throw error;
    res.status(201).json(data);
  } catch (err) { next(err); }
});

// PUT /api/objects/:objectId
router.put('/:objectId', async (req, res, next) => {
  try {
    const body = UpdatePlacedObjectSchema.parse(req.body);
    const { data, error } = await supabaseAdmin
      .from('cd_placed_objects')
      .update({ ...body, updated_at: new Date().toISOString() })
      .eq('object_id', req.params.objectId)
      .select()
      .single();

    if (error) throw error;
    if (!data) return res.status(404).json({ error: 'Object not found' });
    res.json(data);
  } catch (err) { next(err); }
});

// DELETE /api/objects/:objectId
router.delete('/:objectId', async (req, res, next) => {
  try {
    const { error } = await supabaseAdmin
      .from('cd_placed_objects')
      .delete()
      .eq('object_id', req.params.objectId);

    if (error) throw error;
    res.status(204).end();
  } catch (err) { next(err); }
});

// PUT /api/objects/batch — bulk upsert objects for a room
router.put('/batch', async (req, res, next) => {
  try {
    const { room_id, objects } = req.body;
    if (!room_id || !Array.isArray(objects)) {
      return res.status(400).json({ error: 'room_id and objects[] required' });
    }

    // Delete then re-insert
    await supabaseAdmin.from('cd_placed_objects').delete().eq('room_id', room_id);

    if (objects.length > 0) {
      const rows = objects.map((obj, i) => ({
        ...CreatePlacedObjectSchema.parse({ ...obj, room_id }),
        sort_order: i,
      }));

      const { data, error } = await supabaseAdmin
        .from('cd_placed_objects')
        .insert(rows)
        .select();

      if (error) throw error;
      return res.json(data);
    }

    res.json([]);
  } catch (err) { next(err); }
});

export default router;
