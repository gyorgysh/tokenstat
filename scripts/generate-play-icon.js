#!/usr/bin/env node
// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Rasterize Play listing graphics from the SVGs in apps/android/store/.
// Needs `sharp` (the website repo already has it):
//
//   NODE_PATH=../www/node_modules node scripts/generate-play-icon.js

const { readFileSync, writeFileSync, mkdirSync } = require("fs");
const { dirname, join } = require("path");

const root = join(dirname(__filename), "..");
const store = join(root, "apps/android/store");

let sharp;
try {
  sharp = require("sharp");
} catch (err) {
  console.error("error: sharp is required. NODE_PATH=../www/node_modules node scripts/generate-play-icon.js");
  process.exit(1);
}

async function raster({ svg, png, width, height, flatten, alpha, density }) {
  let img = sharp(readFileSync(join(store, svg)), { density: density ?? 1024 }).resize(width, height, {
    fit: "fill",
  });
  img = img.flatten({ background: flatten });
  if (alpha) img = img.ensureAlpha();
  else img = img.removeAlpha();
  const buf = await img.withMetadata({ density: 72 }).png({ compressionLevel: 9, adaptiveFiltering: true }).toBuffer();
  writeFileSync(join(store, png), buf);
  console.log(`wrote ${png} (${buf.length} bytes)`);
}

mkdirSync(store, { recursive: true });

(async () => {
  await raster({
    svg: "play-icon.svg",
    png: "play-icon-512.png",
    width: 512,
    height: 512,
    flatten: "#0d0a18",
    alpha: true,
  });
  await raster({
    svg: "play-icon-mono-white.svg",
    png: "play-icon-mono-white-512.png",
    width: 512,
    height: 512,
    flatten: "#fbfbfd",
    alpha: true,
  });
  await raster({
    svg: "play-icon-mono-black.svg",
    png: "play-icon-mono-black-512.png",
    width: 512,
    height: 512,
    flatten: "#171722",
    alpha: true,
  });
  await raster({
    svg: "play-feature-graphic.svg",
    png: "play-feature-graphic.png",
    width: 1024,
    height: 500,
    flatten: "#fbfbfd",
    alpha: false,
    density: 288,
  });
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
