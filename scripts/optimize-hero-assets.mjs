import { stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const assetsDir = path.join(root, 'assets');

const targets = [
  {
    input: 'voltfriq-home-mobile-hero.png',
    output: 'voltfriq-home-mobile-hero',
    width: 760,
    webpQuality: 56,
    avifQuality: 42
  },
  {
    input: 'voltfriq-home-desktop-hero.png',
    output: 'voltfriq-home-desktop-hero',
    width: 1440,
    webpQuality: 62,
    avifQuality: 45
  },
  {
    input: 'voltfriq-home-hero.png',
    output: 'voltfriq-home-hero',
    width: 900,
    webpQuality: 60,
    avifQuality: 44
  }
];

async function formatSize(file) {
  const bytes = (await stat(file)).size;
  return Math.round(bytes / 1024) + 'KB';
}

for (const target of targets) {
  const inputPath = path.join(assetsDir, target.input);
  const webpPath = path.join(assetsDir, target.output + '.webp');
  const avifPath = path.join(assetsDir, target.output + '.avif');
  const base = sharp(inputPath).rotate().resize({
    width: target.width,
    withoutEnlargement: true
  });

  await base.clone().webp({
    quality: target.webpQuality,
    effort: 6,
    smartSubsample: true
  }).toFile(webpPath);

  await base.clone().avif({
    quality: target.avifQuality,
    effort: 6
  }).toFile(avifPath);

  console.log(`${target.output}: webp ${await formatSize(webpPath)}, avif ${await formatSize(avifPath)}`);
}
