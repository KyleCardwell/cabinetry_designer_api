import express from 'express';
import cors from 'cors';
import { env } from './config/env.js';
import { errorHandler } from './middleware/errorHandler.js';

const app = express();

// Global middleware
app.use(cors({ origin: true, credentials: true }));
app.use(express.json({ limit: '5mb' }));

// Health check (no auth)
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Error handler (must be last)
app.use(errorHandler);

app.listen(env.port, () => {
  console.log(`Cabinetry Designer API running on port ${env.port}`);
});
