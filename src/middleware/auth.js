import { supabaseAdmin } from '../config/supabase.js';

/**
 * Middleware: verify Supabase JWT and attach user + team info to req.
 */
export async function requireAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing authorization header' });
  }

  const token = authHeader.slice(7);

  try {
    const { data: { user }, error } = await supabaseAdmin.auth.getUser(token);
    if (error || !user) {
      return res.status(401).json({ error: 'Invalid or expired token' });
    }

    // Fetch team membership
    const { data: membership } = await supabaseAdmin
      .from('team_members')
      .select('team_id, role')
      .eq('user_id', user.id)
      .single();

    req.user = user;
    req.teamId = membership?.team_id ?? null;
    req.userRole = membership?.role ?? null;
    req.accessToken = token;

    next();
  } catch (err) {
    console.error('Auth middleware error:', err);
    return res.status(500).json({ error: 'Authentication failed' });
  }
}
