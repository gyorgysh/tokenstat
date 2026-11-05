// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Run with: node apps/charts/tests/chart-export-lifecycle.mjs
import assert from 'node:assert/strict';
import { chromium, webkit } from 'playwright';
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { basename } from 'node:path';

const runtime = new URL('../runtime/', import.meta.url);
const example = JSON.parse(readFileSync(new URL('../examples.json', import.meta.url)))[0];
const server = createServer((request, response) => {
    const file = basename(new URL(request.url, 'http://localhost').pathname);
    if (!['index.html', 'chart.js', 'chart.css', 'engine.js', 'contract.js', 'Manrope.ttf'].includes(file)) {
        response.writeHead(404).end();
        return;
    }
    response.setHeader('Content-Type', file.endsWith('.js') ? 'application/javascript'
        : file.endsWith('.css') ? 'text/css' : file.endsWith('.ttf') ? 'font/ttf' : 'text/html');
    response.end(readFileSync(new URL(file, runtime)));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}/index.html`;
let failures = 0;
try {
    for (const [name, engine] of [['chromium', chromium], ['webkit', webkit]]) {
        const browser = await engine.launch({headless: true});
        try {
            for (const scenario of ['replacement-success', 'replacement-error', 'invalid-replacement',
                'current-success', 'current-error', 'disposed-success', 'disposed-error',
                'copy-current', 'copy-replacement', 'copy-disposed']) {
                const page = await browser.newPage({viewport: {width: 640, height: 800}});
                const errors = [];
                page.on('pageerror', error => errors.push(error.message));
                try {
                    await page.goto(url);
                    await page.waitForFunction(() => !!window.TokenstatChart);
                    await page.evaluate(() => document.fonts.ready);
                    await page.evaluate(example => {
                        window.messages = [];
                        window.chrome = {webview: {postMessage: message => messages.push(message)}};
                        window.renderChart = (title, invalid = false) => TokenstatChart.render(
                            invalid ? {...example, type: 'unknown'} : {...example, title},
                            // Omit paintToken: older callers need the same lifecycle protection.
                            {reducedMotion: true},
                        );
                        renderChart('Original chart');
                    }, example);
                    await page.waitForFunction(() => TokenstatChart.inspect().valid);
                    if (scenario.startsWith('copy-')) {
                        await page.evaluate(() => {
                            delete window.chrome;
                            Object.defineProperty(navigator, 'clipboard', {value: {
                                writeText: text => new Promise(resolve => {
                                    window.copiedText = text;
                                    window.finishCopy = resolve;
                                }),
                            }});
                            document.querySelector('#plot').dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter'}));
                            window.job = document.querySelector('#copy').onclick();
                        });
                        await page.waitForFunction(() => !!window.finishCopy);
                        await page.evaluate(dispose => {
                            if (dispose) TokenstatChart.dispose();
                            else if (dispose !== null) renderChart('Replacement chart');
                            finishCopy();
                            return job;
                        }, scenario === 'copy-current' ? null : scenario === 'copy-disposed');
                        assert.match(await page.evaluate(() => copiedText), /^Original chart\n/);
                        assert.equal(await page.locator('#status').textContent(), scenario === 'copy-current'
                            ? 'Selection copied' : '', 'copy status belongs to its chart');
                    } else {
                        await page.evaluate(async () => {
                            await TokenstatChart.exportChart('png');
                            window.referencePNG = messages.find(message => message.type === 'export').content;
                            messages.length = 0;
                            document.querySelector('#status').textContent = '';
                            window.encodedImages = 0;
                            const encode = HTMLCanvasElement.prototype.toDataURL;
                            HTMLCanvasElement.prototype.toDataURL = function (...args) {
                                encodedImages++;
                                return encode.apply(this, args);
                            };
                            const decode = Image.prototype.decode;
                            Image.prototype.decode = function () {
                                window.exportSVG = decodeURIComponent(this.src.split(',')[1]);
                                return new Promise((resolve, reject) => {
                                    window.finishDecode = fail => fail
                                        ? reject(new Error('Held image decode failed'))
                                        : decode.call(this).then(resolve, reject);
                                });
                            };
                            const select = document.querySelector('#export');
                            const change = select.onchange;
                            select.onchange = event => { window.job = change(event); return job; };
                        });
                        await page.selectOption('#export', 'png');
                        await page.waitForFunction(() => !!window.finishDecode);
                        assert.equal(await page.locator('body > div').count(), 0, 'release the export renderer before decoding');
                        const disposed = scenario.startsWith('disposed-');
                        const invalid = scenario === 'invalid-replacement';
                        const replaced = scenario.startsWith('replacement-') || invalid;
                        await page.evaluate(({disposed, replaced, invalid}) => {
                            if (disposed) TokenstatChart.dispose();
                            else if (replaced) renderChart('Replacement chart', invalid);
                        }, {disposed, replaced, invalid});
                        assert.match(await page.evaluate(() => exportSVG), /Original chart/);
                        const failure = scenario.endsWith('-error');
                        await page.evaluate(failure => { finishDecode(failure); return job; }, failure);
                        const exports = await page.evaluate(() => messages.filter(message => message.type === 'export'));
                        assert.equal(exports.length, disposed || failure ? 0 : 1, 'only valid requested exports reach the host');
                        if (exports.length) {
                            assert.equal(exports[0].name, 'chart.png');
                            assert.equal(exports[0].content, await page.evaluate(() => referencePNG), 'export preserves the requested chart pixels');
                        }
                        assert.equal(await page.locator('#status').textContent(), scenario === 'current-error'
                            ? 'Held image decode failed' : scenario === 'current-success' ? 'Export ready' : '',
                            'export status belongs to its chart');
                        assert.equal(await page.evaluate(() => encodedImages), disposed || failure ? 0 : 1,
                            'do not encode an image after disposal or decode failure');
                        assert.equal(await page.locator('body > div').count(), 0, 'release the temporary export chart');
                        if (invalid) assert.equal(await page.locator('#error').isVisible(), true);
                        else if (replaced) assert.equal(await page.locator('#title').textContent(), 'Replacement chart');
                    }
                    assert.deepEqual(errors, [], 'no unhandled browser errors');
                    console.log(`${name}: ${scenario} passed`);
                } catch (error) {
                    failures++;
                    console.error(`${name}: ${scenario}: ${error.stack}`);
                } finally { await page.close(); }
            }
        } finally { await browser.close(); }
    }
} finally { await new Promise(resolve => server.close(resolve)); }
assert.equal(failures, 0, `${failures} chart action lifecycle checks failed`);
