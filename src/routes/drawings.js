import { Router } from 'express';
import { drawingPayloadSchema } from '../schemas/drawingPayload.js';
import { runGeometry } from '../services/geometryBridge.js';
import { drawingZipName } from '../services/fileNames.js';

const router = Router();

router.post('/preview', async (req, res, next) => {
  try {
    const payload = drawingPayloadSchema.parse(req.body);
    const result = await runGeometry('draw', payload);
    res.set({
      'Content-Type': 'application/zip',
      'Content-Disposition': `attachment; filename="${drawingZipName(payload.room.name)}"`,
      'X-Drawing-Files': result.files.join(','),
    });
    res.send(Buffer.from(result.zip_base64, 'base64'));
  } catch (err) {
    next(err);
  }
});

export default router;
