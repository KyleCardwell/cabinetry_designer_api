import { Router } from 'express';
import crypto from 'crypto';
import { supabaseAdmin } from '../config/supabase.js';
import { resolveRoom } from '../services/parameterResolver.js';
import { generateRoom } from '../services/geometryBridge.js';

const router = Router();

// POST /api/rooms/:roomId/generate — trigger DXF + report generation
router.post('/:roomId/generate', async (req, res, next) => {
  try {
    // 1. Fetch room + walls + objects
    const { data: room, error: roomErr } = await supabaseAdmin
      .from('cd_rooms')
      .select('*')
      .eq('room_id', req.params.roomId)
      .single();
    if (roomErr || !room) return res.status(404).json({ error: 'Room not found' });

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

    // 2. Resolve all parameters
    const resolvedRoom = resolveRoom(room, walls ?? [], objects ?? [], project, teamDefaults);

    // 3. Check cache by input hash
    const inputJson = JSON.stringify(resolvedRoom);
    const inputHash = crypto.createHash('sha256').update(inputJson).digest('hex');

    const { data: cached } = await supabaseAdmin
      .from('cd_generations')
      .select('*')
      .eq('room_id', room.room_id)
      .eq('input_hash', inputHash)
      .eq('status', 'complete')
      .order('generated_at', { ascending: false })
      .limit(1)
      .single();

    if (cached) {
      return res.json({
        generation_id: cached.generation_id,
        dxf_url: cached.dxf_url,
        reports: cached.reports,
        cached: true,
      });
    }

    // 4. Create pending generation record
    const { data: generation } = await supabaseAdmin
      .from('cd_generations')
      .insert({ room_id: room.room_id, input_hash: inputHash, status: 'processing' })
      .select()
      .single();

    // 5. Call geometry engine
    let result;
    try {
      result = await generateRoom(resolvedRoom);
    } catch (engineErr) {
      await supabaseAdmin
        .from('cd_generations')
        .update({ status: 'error' })
        .eq('generation_id', generation.generation_id);
      throw engineErr;
    }

    // 6. Upload DXF to Supabase Storage
    let dxfUrl = null;
    if (result.dxf_base64) {
      const dxfBuffer = Buffer.from(result.dxf_base64, 'base64');
      const storagePath = `dxf/${room.room_id}/${generation.generation_id}.dxf`;

      const { error: uploadErr } = await supabaseAdmin.storage
        .from('cd-drawings')
        .upload(storagePath, dxfBuffer, { contentType: 'application/dxf', upsert: true });

      if (!uploadErr) {
        const { data: urlData } = supabaseAdmin.storage
          .from('cd-drawings')
          .getPublicUrl(storagePath);
        dxfUrl = urlData?.publicUrl ?? null;
      }
    }

    // 7. Update generation record
    await supabaseAdmin
      .from('cd_generations')
      .update({
        status: 'complete',
        dxf_url: dxfUrl,
        reports: result.reports ?? null,
      })
      .eq('generation_id', generation.generation_id);

    res.json({
      generation_id: generation.generation_id,
      dxf_url: dxfUrl,
      reports: result.reports,
      cached: false,
    });
  } catch (err) { next(err); }
});

export default router;
