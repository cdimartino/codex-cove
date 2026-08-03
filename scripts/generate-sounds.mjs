import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const outputDirectory = path.join(scriptDirectory, "..", "Resources", "Sounds");
const sampleRate = 22_050;

function squareWave(notes) {
  const samples = [];
  for (const note of notes) {
    const count = Math.round(sampleRate * note.seconds);
    const attack = Math.max(1, Math.round(count * 0.08));
    const release = Math.max(1, Math.round(count * 0.25));
    for (let index = 0; index < count; index += 1) {
      const phase = (index * note.hz) / sampleRate;
      const raw = Math.sin(phase * Math.PI * 2) >= 0 ? 1 : -1;
      const attackGain = Math.min(1, index / attack);
      const releaseGain = Math.min(1, (count - index) / release);
      const gain = Math.min(attackGain, releaseGain) * note.volume;
      samples.push(Math.round(raw * gain * 32_767));
    }
  }
  return samples;
}

function wavBuffer(samples) {
  const dataBytes = samples.length * 2;
  const buffer = Buffer.alloc(44 + dataBytes);
  buffer.write("RIFF", 0);
  buffer.writeUInt32LE(36 + dataBytes, 4);
  buffer.write("WAVE", 8);
  buffer.write("fmt ", 12);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36);
  buffer.writeUInt32LE(dataBytes, 40);
  samples.forEach((sample, index) => buffer.writeInt16LE(sample, 44 + index * 2));
  return buffer;
}

const sounds = {
  "task-completed.wav": [
    { hz: 523.25, seconds: 0.08, volume: 0.16 },
    { hz: 659.25, seconds: 0.08, volume: 0.18 },
    { hz: 783.99, seconds: 0.14, volume: 0.20 },
  ],
  "needs-input.wav": [
    { hz: 440.00, seconds: 0.11, volume: 0.13 },
    { hz: 659.25, seconds: 0.14, volume: 0.17 },
  ],
  "approval-requested.wav": [
    { hz: 587.33, seconds: 0.07, volume: 0.14 },
    { hz: 587.33, seconds: 0.07, volume: 0.14 },
    { hz: 739.99, seconds: 0.12, volume: 0.18 },
  ],
  "task-failed.wav": [
    { hz: 392.00, seconds: 0.10, volume: 0.15 },
    { hz: 329.63, seconds: 0.10, volume: 0.16 },
    { hz: 261.63, seconds: 0.18, volume: 0.18 },
  ],
};

fs.mkdirSync(outputDirectory, { recursive: true });
for (const [name, notes] of Object.entries(sounds)) {
  fs.writeFileSync(path.join(outputDirectory, name), wavBuffer(squareWave(notes)));
}

console.log(outputDirectory);

