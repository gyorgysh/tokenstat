// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Run with: node tests/model-lifecycle.mjs
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { chromium, webkit } from 'playwright';
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
// Keep the real renderer and GPU resources. Delay only the loader so a test
// can close or replace the preview while parsing is pending.
const bundle = await build({
    stdin: { contents: `
        export { load, dispose } from './model-engine.mjs';
        import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
        import { BoxGeometry, Mesh, MeshStandardMaterial } from 'three';
        const pending = [];
        export const released = [];
        GLTFLoader.prototype.parseAsync = function () {
            return new Promise((resolve, reject) => pending.push({resolve, reject}));
        };
        export function finish(index, fail = false) {
            if (fail) { pending[index].reject(new Error('Old load failed')); return; }
            const mesh = new Mesh(new BoxGeometry(), new MeshStandardMaterial());
            released[index] = 0;
            for (const resource of [mesh.geometry, mesh.material]) {
                resource.addEventListener('dispose', () => released[index]++);
            }
            pending[index].resolve({scene: mesh});
        }
    `, resolveDir: root, sourcefile: 'model-lifecycle-entry.mjs' },
    bundle: true, write: false, format: 'iife', globalName: 'TokenstatModel',
});
const server = createServer((req, res) => {
    const script = req.url === '/model-engine.js';
    res.setHeader('Content-Type', script ? 'application/javascript' : 'text/html');
    res.end(script ? bundle.outputFiles[0].text : readFileSync(new URL('../runtime/model.html', import.meta.url)));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}/model.html`;
try {
    for (const [name, engine] of [['chromium', chromium], ['webkit', webkit]]) {
        const browser = await engine.launch({headless: true});
        try {
            const page = await browser.newPage({viewport: {width: 640, height: 360}});
            const errors = [];
            page.on('pageerror', error => errors.push(error.message));
            await page.addInitScript(() => {
                window.probe = {observers: 0, glCalls: 0};
                const Original = window.ResizeObserver;
                window.ResizeObserver = class extends Original {
                    observe(...args) { if (!this.tracked) { this.tracked = true; probe.observers++; } return super.observe(...args); }
                    disconnect() { if (this.tracked) { this.tracked = false; probe.observers--; } return super.disconnect(); }
                };
                for (const Type of [window.WebGLRenderingContext, window.WebGL2RenderingContext]) {
                    if (!Type) continue;
                    for (const method of ['drawArrays', 'drawElements', 'viewport', 'clear']) {
                        const original = Type.prototype[method];
                        Type.prototype[method] = function (...args) { probe.glCalls++; return original.apply(this, args); };
                    }
                }
            });
            await page.goto(url);
            await page.evaluate(() => { window.pendingLoad = TokenstatModel.load('', 'gltf', '#100d1c'); });
            await page.evaluate(() => { TokenstatModel.dispose(); TokenstatModel.finish(0); });
            assert.equal(await page.evaluate(() => pendingLoad), false, `${name}: a disposed load must not publish`);
            assert.equal(await page.evaluate(() => TokenstatModel.released[0]), 2, `${name}: release late geometry and material`);
            assert.equal(await page.evaluate(() => probe.observers), 0, `${name}: disconnect resize observers`);
            const calls = await page.evaluate(() => probe.glCalls);
            await page.setViewportSize({width: 500, height: 320});
            await page.waitForTimeout(150);
            assert.equal(await page.evaluate(() => probe.glCalls), calls, `${name}: no GPU work after disposal`);
            assert.equal(await page.evaluate(() => TokenstatModel.load('', 'gltf', '#ffffff')), false);

            await page.goto(url);
            await page.evaluate(() => {
                window.oldLoad = TokenstatModel.load('', 'gltf', '#100d1c');
                window.newLoad = TokenstatModel.load('', 'gltf', '#ffffff');
                TokenstatModel.finish(1);
            });
            assert.equal(await page.evaluate(() => newLoad), true);
            await page.evaluate(() => TokenstatModel.finish(0));
            assert.equal(await page.evaluate(() => oldLoad), false, `${name}: stale success must not replace current model`);
            assert.deepEqual(await page.evaluate(() => [...TokenstatModel.released]), [2, 0]);
            assert.equal(await page.locator('#status').isHidden(), true);
            await page.evaluate(() => { TokenstatModel.dispose(); TokenstatModel.dispose(); });
            assert.deepEqual(await page.evaluate(() => [...TokenstatModel.released]), [2, 2], `${name}: disposal is idempotent`);

            await page.goto(url);
            await page.evaluate(() => {
                window.oldLoad = TokenstatModel.load('', 'gltf', '#100d1c');
                window.newLoad = TokenstatModel.load('', 'gltf', '#ffffff');
                TokenstatModel.finish(1);
            });
            assert.equal(await page.evaluate(() => newLoad), true);
            await page.evaluate(() => TokenstatModel.finish(0, true));
            assert.equal(await page.evaluate(() => oldLoad), false);
            assert.equal(await page.locator('#status').isHidden(), true, `${name}: stale errors must not replace current status`);
            assert.notEqual(await page.locator('#status').textContent(), 'Old load failed');
            await page.evaluate(() => window.dispatchEvent(new Event('pagehide')));
            assert.equal(await page.evaluate(() => TokenstatModel.released[1]), 2, `${name}: page closure releases the model`);
            assert.deepEqual(errors, []);
            console.log(`${name}: pending loads, replacements, errors, resizing and disposal passed`);
        } finally { await browser.close(); }
    }
} finally { await new Promise(resolve => server.close(resolve)); }
