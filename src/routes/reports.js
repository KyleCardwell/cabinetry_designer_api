import { Router } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { resolveRoom } from '../services/parameterResolver.js';
import {
  buildShippingList,
  buildDoorList,
  buildDrawerFrontList,
  buildDrawerBoxList,
} from '../services/reportBuilder.js';

const router = Router();

// GET /api/rooms/:roomId/reports — quick reports without DXF generation
router.get('/:roomId/reports', async (req, res, next) => {
  try {
    const { data: room } = await supabaseAdmin
      .from('cd_rooms')
      .select('*')
      .eq('room_id', req.params.roomId)
      .single();
    if (!room) return res.status(404).json({ error: 'Room not found' });

    const { data: project } = await supabaseAdmin
      .from('cd_projects')
      .select('*')
      .eq('project_id', room.project_id)
      .single();
    if (project.team_id !== req.teamId) {
      return res.status(403).json({ error: 'Forbidden' });
    }

    const { data: teamDefaults } = await supabaseAdmin
      .from('cd_team_defaults')
      .select('*')
      .eq('team_id', req.teamId)
      .single();

    const { data: walls } = await supabaseAdmin
      .from('cd_walls')
      .select('*')
      .eq('room_id', room.room_id)
      .order('sort_order');

    const { data: objects } = await supabaseAdmin
      .from('cd_placed_objects')
      .select('*')
      .eq('room_id', room.room_id)
      .order('sort_order');

    const resolvedRoom = resolveRoom(room, walls ?? [], objects ?? [], project, teamDefaults);

    res.json({
      shipping_list: buildShippingList(resolvedRoom.objects),
      door_list: buildDoorList(resolvedRoom.objects),
      drawer_front_list: buildDrawerFrontList(resolvedRoom.objects),
      drawer_box_list: buildDrawerBoxList(resolvedRoom.objects),
    });
  } catch (err) { next(err); }
});

export default router;
