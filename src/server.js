import express from 'express';
import cors from 'cors';
import { env } from './config/env.js';
import { requireAuth } from './middleware/auth.js';
import { errorHandler } from './middleware/errorHandler.js';
import projectRoutes from './routes/projects.js';
import roomRoutes from './routes/rooms.js';
import wallRoutes from './routes/walls.js';
import objectRoutes from './routes/objects.js';
import generateRoutes from './routes/generate.js';
import reportRoutes from './routes/reports.js';

const app = express();

// Global middleware
app.use(cors({ origin: true, credentials: true }));
app.use(express.json({ limit: '5mb' }));

// Health check (no auth)
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Auth-protected routes
app.use('/api/projects', requireAuth, projectRoutes);
app.use('/api/rooms', requireAuth, roomRoutes);
app.use('/api/walls', requireAuth, wallRoutes);
app.use('/api/objects', requireAuth, objectRoutes);
app.use('/api/rooms', requireAuth, generateRoutes);   // POST /api/rooms/:roomId/generate
app.use('/api/rooms', requireAuth, reportRoutes);      // GET  /api/rooms/:roomId/reports

// Error handler (must be last)
app.use(errorHandler);

app.listen(env.port, () => {
  console.log(`Cabinetry Designer API running on port ${env.port}`);
});
