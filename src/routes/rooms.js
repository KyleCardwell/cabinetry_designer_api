import { Router } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { CreateRoomSchema, UpdateRoomSchema } from '../models/room.js';

const router = Router();

// GET /api/rooms/:roomId — full room with walls + objects
router.get('/:roomId', async (req, res, next) => {
  try {
    const { data: room, error } = await supabaseAdmin
      .from('cd_rooms')
      .select('*, cd_projects!inner(team_id), cd_walls(*), cd_placed_objects(*)')
      .eq('room_id', req.params.roomId)
      .single();

    if (error) throw error;
    if (!room) return res.status(404).json({ error: 'Room not found' });
    if (room.cd_projects.team_id !== req.teamId) {
      return res.status(403).json({ error: 'Forbidden' });
    }

    res.json({
      ...room,
      walls: room.cd_walls ?? [],
      objects: room.cd_placed_objects ?? [],
      cd_walls: undefined,
      cd_placed_objects: undefined,
      cd_projects: undefined,
    });
  } catch (err) { next(err); }
});

// POST /api/rooms
router.post('/', async (req, res, next) => {
  try {
    const body = CreateRoomSchema.parse(req.body);

    // Verify project belongs to user's team
    const { data: project } = await supabaseAdmin
      .from('cd_projects')
      .select('team_id')
      .eq('project_id', body.project_id)
      .single();

    if (!project || project.team_id !== req.teamId) {
      return res.status(403).json({ error: 'Forbidden' });
    }

    const { data, error } = await supabaseAdmin
      .from('cd_rooms')
      .insert(body)
      .select()
      .single();

    if (error) throw error;
    res.status(201).json(data);
  } catch (err) { next(err); }
});

// PUT /api/rooms/:roomId
router.put('/:roomId', async (req, res, next) => {
  try {
    const body = UpdateRoomSchema.parse(req.body);

    const { data, error } = await supabaseAdmin
      .from('cd_rooms')
      .update({ ...body, updated_at: new Date().toISOString() })
      .eq('room_id', req.params.roomId)
      .select()
      .single();

    if (error) throw error;
    if (!data) return res.status(404).json({ error: 'Room not found' });
    res.json(data);
  } catch (err) { next(err); }
});

// DELETE /api/rooms/:roomId
router.delete('/:roomId', async (req, res, next) => {
  try {
    const { error } = await supabaseAdmin
      .from('cd_rooms')
      .delete()
      .eq('room_id', req.params.roomId);

    if (error) throw error;
    res.status(204).end();
  } catch (err) { next(err); }
});

export default router;
