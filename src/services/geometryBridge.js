import { spawn } from 'node:child_process';
import { env } from '../config/env.js';

/**
 * Run a geometry command (SPEC-40): JSON on stdin, JSON on stdout.
 * Resolves the parsed stdout. Rejects with an Error carrying `status`:
 *   422 + `details` when geometry exits 2 (invalid payload; stderr is {error, details}),
 *   504 when it runs past timeoutMs (the child is killed),
 *   502 for any other failure (spawn error, other exit code, unparseable stdout), message includes stderr.
 */
export function runGeometry(command, input, {
  python = env.geometryPython,
  args = ['-m', 'src', command],
  cwd = env.geometryEnginePath,
  timeoutMs = env.geometryTimeoutMs,
} = {}) {
  return new Promise((resolve, reject) => {
    const stdout = [];
    const stderr = [];
    let child;
    let timer;
    let settled = false;
    let stdinError;

    const finish = (err, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (err) reject(err);
      else resolve(result);
    };
    const fail = (status, message, details) => {
      const err = new Error(message);
      err.status = status;
      if (details !== undefined) err.details = details;
      finish(err);
    };
    const stderrText = () => Buffer.concat(stderr).toString('utf8');
    const spawnError = (err) => {
      const hint = err.code === 'ENOENT'
        ? ' Create the geometry venv as described in README.md.'
        : '';
      fail(502, `Failed to spawn geometry engine with ${python}: ${err.message}.${hint} ${stderrText()}`);
    };

    try {
      const json = JSON.stringify(input);
      child = spawn(python, args, { cwd, stdio: ['pipe', 'pipe', 'pipe'] });
      child.stdout.on('data', (chunk) => stdout.push(chunk));
      child.stderr.on('data', (chunk) => stderr.push(chunk));
      child.on('error', spawnError);
      // An early engine exit can close stdin; handle it without an unhandled EPIPE.
      child.stdin.on('error', (err) => { stdinError = err; });

      child.on('close', (code, signal) => {
        if (settled) return;
        const errors = stderrText();
        if (code === 2) {
          let validation;
          try { validation = JSON.parse(errors); } catch { /* Keep raw stderr if malformed. */ }
          return fail(422, validation?.error || `Invalid drawing payload: ${errors}`, validation?.details);
        }
        if (code !== 0) {
          return fail(502, `Geometry engine exited with ${signal ? `signal ${signal}` : `code ${code}`}: ${errors}`);
        }
        if (stdinError) {
          return fail(502, `Failed to write geometry input: ${stdinError.message}: ${errors}`);
        }
        try {
          finish(null, JSON.parse(Buffer.concat(stdout).toString('utf8')));
        } catch (err) {
          fail(502, `Failed to parse geometry engine output: ${err.message}: ${errors}`);
        }
      });

      timer = setTimeout(() => {
        child.kill('SIGKILL');
        fail(504, `Geometry engine timed out after ${timeoutMs} ms`);
      }, timeoutMs);
      child.stdin.end(json);
    } catch (err) {
      if (child) child.kill('SIGKILL');
      spawnError(err);
    }
  });
}
