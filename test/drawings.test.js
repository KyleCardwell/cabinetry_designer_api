import assert from 'node:assert/strict';
import { test } from 'node:test';
import { drawingZipName } from '../src/services/fileNames.js';
import { drawingPayloadSchema } from '../src/schemas/drawingPayload.js';

const payload = {
  payloadVersion: 1,
  units: 'in',
  room: { id: '7ee9fabb-5daf-4fb2-96f9-b24b9e1e546f', name: 'G1 Euro kitchen' },
  elevations: [
    {
      key: 'cb33d774-f31e-41c1-bbe4-198cbf981619', letter: 'A', wallId: 'cb33d774-f31e-41c1-bbe4-198cbf981619',
      side: 'front', title: 'Elevation A', wallLabel: 'Wall 1', length: 168, height: 96,
    },
    {
      key: '4afd9749-bbe8-4848-8a67-a1d063bdfce8', letter: 'B', wallId: '4afd9749-bbe8-4848-8a67-a1d063bdfce8',
      side: 'front', title: 'Elevation B', wallLabel: 'Wall 2', length: 120, height: 96,
    },
    {
      key: '84063fed-ab0d-4a1d-ae05-ffe67decad5e', letter: 'C', wallId: '84063fed-ab0d-4a1d-ae05-ffe67decad5e',
      side: 'front', title: 'Elevation C', wallLabel: 'Wall 4', length: 91.5, height: 36,
    },
    {
      key: '84063fed-ab0d-4a1d-ae05-ffe67decad5e:back', letter: 'D', wallId: '84063fed-ab0d-4a1d-ae05-ffe67decad5e',
      side: 'back', title: 'Elevation D', wallLabel: 'Wall 4', length: 91.5, height: 36,
    },
  ],
};

test('names the zip after the room', () => {
  assert.equal(drawingZipName('G1 Euro kitchen'), 'g1-euro-kitchen.zip');
});

test('uses a fallback name and collapses punctuation', () => {
  assert.equal(drawingZipName('  '), 'room.zip');
  assert.equal(drawingZipName('Bath #2 / Main'), 'bath-2-main.zip');
});

test('accepts the G1 drawing payload from SPEC-40', () => {
  assert.deepEqual(drawingPayloadSchema.parse(payload), payload);
});

test('rejects other payload versions and a missing room', () => {
  assert.equal(drawingPayloadSchema.safeParse({ ...payload, payloadVersion: 2 }).success, false);
  const { room, ...withoutRoom } = payload;
  assert.equal(drawingPayloadSchema.safeParse(withoutRoom).success, false);
});
