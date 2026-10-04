const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));

switch (input.mode) {
  case 'ok':
    process.stdout.write(JSON.stringify({
      payloadVersion: 1,
      files: ['elevation-A.dxf'],
      zip_base64: 'UEsFBgAAAAAAAAAAAAAAAAAAAAAAAA==',
    }));
    break;
  case 'invalid':
    process.stderr.write(JSON.stringify({
      error: 'Invalid drawing payload',
      details: [{ loc: ['units'] }],
    }));
    process.exitCode = 2;
    break;
  case 'crash':
    process.stderr.write('boom');
    process.exitCode = 1;
    break;
  case 'hang':
    setInterval(() => {}, 1000);
    break;
}
