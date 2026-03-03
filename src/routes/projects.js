import { Router } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { CreateProjectSchema, UpdateProjectSchema } from '../models/project.js';

const router = Router();

// GET /api/projects?team_id=...
router.get('/', async (req, res, next) => {
  try {
    const { team_id } = req.query;
    if (!team_id) return res.status(400).json({ error: 'team_id required' });

    // Verify requester belongs to this team
    if (req.teamId !== team_id) {
      return res.status(403).json({ error: 'Not a member of this team' });
    }

    const { data, error } = await supabaseAdmin
      .from('cd_projects')
      .select('*, cd_rooms(room_id, name, sort_order)')
      .eq('team_id', team_id)
      .order('created_at', { ascending: false });

    if (error) throw error;
    res.json(data);
  } catch (err) { next(err); }
});

// GET /api/projects/:projectId
router.get('/:projectId', async (req, res, next) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('cd_projects')
      .select('*, cd_rooms(room_id, name, sort_order)')
      .eq('project_id', req.params.projectId)
      .single();

    if (error) throw error;
    if (!data) return res.status(404).json({ error: 'Project not found' });
    if (data.team_id !== req.teamId) return res.status(403).json({ error: 'Forbidden' });

    res.json(data);
  } catch (err) { next(err); }
});

// POST /api/projects
router.post('/', async (req, res, next) => {
  try {
    const body = CreateProjectSchema.parse(req.body);
    if (body.team_id !== req.teamId) {
      return res.status(403).json({ error: 'Cannot create project for another team' });
    }

    const { data, error } = await supabaseAdmin
      .from('cd_projects')
      .insert({ ...body, created_by: req.user.id })
      .select()
      .single();

    if (error) throw error;
    res.status(201).json(data);
  } catch (err) { next(err); }
});

// PUT /api/projects/:projectId
router.put('/:projectId', async (req, res, next) => {
  try {
    const body = UpdateProjectSchema.parse(req.body);

    const { data, error } = await supabaseAdmin
      .from('cd_projects')
      .update({ ...body, updated_at: new Date().toISOString() })
      .eq('project_id', req.params.projectId)
      .eq('team_id', req.teamId)
      .select()
      .single();

    if (error) throw error;
    if (!data) return res.status(404).json({ error: 'Project not found' });
    res.json(data);
  } catch (err) { next(err); }
});

// DELETE /api/projects/:projectId
router.delete('/:projectId', async (req, res, next) => {
  try {
    const { error } = await supabaseAdmin
      .from('cd_projects')
      .delete()
      .eq('project_id', req.params.projectId)
      .eq('team_id', req.teamId);

    if (error) throw error;
    res.status(204).end();
  } catch (err) { next(err); }
});

export default router;
