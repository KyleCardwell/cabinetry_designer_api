import { supabaseAuth } from '../config/supabase.js';

/**
 * Middleware: verify the Supabase login and attach user + access token to req.
 */
export async function requireAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing authorization header' });
  }

  const token = authHeader.slice(7);

  try {
    const { data: { user }, error } = await supabaseAuth.auth.getUser(token);
    if (error || !user) {
      return res.status(401).json({ error: 'Invalid or expired token' });
    }

    req.user = user;
    req.accessToken = token;

    next();
  } catch (err) {
    console.error('Auth middleware error:', err);
    return res.status(500).json({ error: 'Authentication failed' });
  }
}
