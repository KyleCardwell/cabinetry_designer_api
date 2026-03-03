import { spawn } from 'child_process';
import path from 'path';
import { env } from '../config/env.js';

/**
 * Invoke the Python geometry engine via CLI.
 * Sends resolved room JSON on stdin, receives { dxf_base64, reports } on stdout.
 */
export function generateRoom(resolvedRoom) {
  return new Promise((resolve, reject) => {
    const enginePath = path.resolve(env.geometryEnginePath);
    const child = spawn('python', ['-m', 'src.cli', 'generate'], {
      cwd: enginePath,
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
    child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });

    child.on('close', (code) => {
      if (code !== 0) {
        return reject(new Error(`Geometry engine exited with code ${code}: ${stderr}`));
      }
      try {
        const result = JSON.parse(stdout);
        resolve(result);
      } catch (parseErr) {
        reject(new Error(`Failed to parse geometry engine output: ${parseErr.message}`));
      }
    });

    child.on('error', (err) => {
      reject(new Error(`Failed to spawn geometry engine: ${err.message}`));
    });

    // Send resolved room JSON to stdin
    child.stdin.write(JSON.stringify(resolvedRoom));
    child.stdin.end();
  });
}
