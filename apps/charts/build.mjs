// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Pinned dependencies and npm's integrity lock make the bundled runtime reproducible.
import { build } from "esbuild";
import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
const result = await build({
    entryPoints: [fileURLToPath(new URL("engine.mjs", import.meta.url))],
    bundle: true,
    minify: true,
    format: "iife",
    globalName: "TokenstatChartEngine",
    target: ["safari15", "chrome100"],
    legalComments: "external",
    outfile: "engine.js",
    write: false,
});
const code = result.outputFiles.find((file) => file.path.endsWith("engine.js"));
const notices = result.outputFiles.find((file) =>
    file.path.endsWith(".LEGAL.txt"),
);
if (!code || !notices)
    throw new Error("The engine or its dependency notices are missing");
const bytes = Buffer.from(
    "/*! Apache ECharts. Dependency notices: ENGINE-LICENSE.txt */\n" +
        code.text,
);
if (bytes.length > 1024 * 1024)
    throw new Error("The chart engine exceeds the bundled asset limit");
writeFileSync(new URL("runtime/engine.js", import.meta.url), bytes);
const license = [
    "Apache ECharts 6.1.0\n",
    notices.text.replace(/[ \t]+$/gm, ""),
    readFileSync(
        new URL("node_modules/echarts/LICENSE", import.meta.url),
        "utf8",
    ),
    "\nApache ECharts NOTICE\n",
    readFileSync(
        new URL("node_modules/echarts/NOTICE", import.meta.url),
        "utf8",
    ),
    "\nd3 subcomponents\n",
    readFileSync(
        new URL("node_modules/echarts/licenses/LICENSE-d3", import.meta.url),
        "utf8",
    ),
    "\nzrender\n",
    readFileSync(
        new URL("node_modules/zrender/LICENSE", import.meta.url),
        "utf8",
    ),
].join("\n");
writeFileSync(new URL("runtime/ENGINE-LICENSE.txt", import.meta.url), license);
writeFileSync(
    new URL("runtime/engine-manifest.json", import.meta.url),
    JSON.stringify(
        {
            name: "Apache ECharts",
            version: "6.1.0",
            sha256: createHash("sha256").update(bytes).digest("hex"),
            bytes: bytes.length,
        },
        null,
        2,
    ) + "\n",
);
console.log(`Bundled chart engine: ${bytes.length} bytes`);

const modelResult = await build({
    entryPoints: [fileURLToPath(new URL("model-engine.mjs", import.meta.url))],
    bundle: true,
    minify: true,
    format: "iife",
    globalName: "TokenstatModel",
    target: ["safari15", "chrome100"],
    legalComments: "external",
    outfile: "model-engine.js",
    write: false,
});
const modelCode = modelResult.outputFiles.find((file) => file.path.endsWith("model-engine.js"));
const modelNotices = modelResult.outputFiles.find((file) => file.path.endsWith(".LEGAL.txt"));
if (!modelCode || !modelNotices) throw new Error("The model engine or its license notice is missing");
const modelBytes = Buffer.from("/*! Three.js. Dependency notices: MODEL-LICENSE.txt */\n" +
    modelCode.text.replace(/[ \t]+$/gm, "").replace(/^ +\t/gm, "\t"));
if (modelBytes.length > 2 * 1024 * 1024) throw new Error("The model engine exceeds the bundled asset limit");
writeFileSync(new URL("runtime/model-engine.js", import.meta.url), modelBytes);
writeFileSync(new URL("runtime/MODEL-LICENSE.txt", import.meta.url),
    "\n\n## Three.js 0.186.1 (MIT)\n" + modelNotices.text + "\n" +
    readFileSync(new URL("node_modules/three/LICENSE", import.meta.url), "utf8"));
console.log(`Bundled model engine: ${modelBytes.length} bytes`);

// Reuse the app's existing interface face, including its redistribution notice.
for (const [source, target] of [
    ["Manrope-Variable.ttf", "Manrope.ttf"],
    ["Manrope-OFL.txt", "FONT-LICENSE.txt"],
]) {
    writeFileSync(
        new URL("runtime/" + target, import.meta.url),
        target.endsWith(".txt")
            ? readFileSync(
                  new URL("../mac/Resources/Fonts/" + source, import.meta.url),
                  "utf8",
              ).replace(/[ \t]+$/gm, "")
            : readFileSync(
                  new URL("../mac/Resources/Fonts/" + source, import.meta.url),
              ),
    );
}
