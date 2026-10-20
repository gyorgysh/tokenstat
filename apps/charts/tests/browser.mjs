// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import { chromium, webkit } from "playwright";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { resolve, basename } from "node:path";
const root = resolve(import.meta.dirname, "../runtime");
const examples = JSON.parse(readFileSync(resolve(root, "../examples.json")));
const output = resolve(
    process.env.TOKENSTAT_CHART_TEST_OUTPUT || "target/charts-review/browser",
);
mkdirSync(output, { recursive: true });
const server = createServer((request, response) => {
    const file = basename(new URL(request.url, "http://localhost").pathname);
    if (
        ![
            "index.html",
            "engine.js",
            "contract.js",
            "chart.js",
            "chart.css",
            "Manrope.ttf",
        ].includes(file)
    ) {
        response.writeHead(403).end();
        return;
    }
    response.setHeader(
        "Content-Type",
        file.endsWith(".js")
            ? "application/javascript"
            : file.endsWith(".css")
              ? "text/css"
              : file.endsWith(".ttf")
                ? "font/ttf"
                : "text/html",
    );
    response.end(readFileSync(resolve(root, file)));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = "http://127.0.0.1:" + server.address().port + "/index.html";
let cases = 0;
try {
    for (const [name, engine] of [
        ["chromium", chromium],
        ["webkit", webkit],
    ]) {
        const browser = await engine.launch({ headless: true });
        try {
            for (const width of [320, 768, 1200]) {
                const context = await browser.newContext({
                    viewport: { width, height: 1000 },
                    hasTouch: width === 320,
                    deviceScaleFactor: width === 320 ? 2 : 1,
                });
                const page = await context.newPage(),
                    errors = [];
                page.on("pageerror", (error) => errors.push(error.message));
                let external = 0;
                page.on("request", (request) => {
                    if (!request.url().startsWith("http://127.0.0.1:"))
                        external++;
                });
                try {
                    await page.goto(address);
                    await page.waitForFunction(() => !!window.TokenstatChart);
                    await page.evaluate(() => document.fonts.ready);
                    for (const dark of [false, true]) {
                        for (const spec of examples) {
                            await page.evaluate(
                                ({ spec, dark }) =>
                                    window.TokenstatChart.render(spec, {
                                        dark,
                                        reducedMotion: true,
                                        locale: "en-US",
                                    }),
                                { spec, dark },
                            );
                            assert.equal(
                                await page.evaluate(
                                    () => window.TokenstatChart.inspect().valid,
                                ),
                                true,
                                name + " " + spec.type,
                            );
                            assert.equal(
                                await page.locator("#error").isVisible(),
                                false,
                            );
                            assert.ok(
                                (await page.locator("#plot svg path").count()) >
                                    0,
                            );
                            assert.ok(
                                await page.evaluate(
                                    () =>
                                        document.documentElement.scrollWidth <=
                                        innerWidth + 1,
                                ),
                                "horizontal overflow " +
                                    spec.type +
                                    " " +
                                    width,
                            );
                            await page.locator("#plot").focus();
                            await page.keyboard.press("ArrowRight");
                            assert.ok(
                                await page.locator("#selection").innerText(),
                            );
                            await page.locator("#table-toggle").click();
                            assert.equal(
                                await page.locator("#data-panel").isVisible(),
                                true,
                            );
                            assert.ok(
                                (await page.locator("#rows tr").count()) > 0,
                            );
                            await page.locator("#table-toggle").click();
                            if (
                                width === 320 &&
                                ["bar", "donut", "heatmap"].includes(spec.type)
                            )
                                await page.screenshot({
                                    path: resolve(
                                        output,
                                        `${name}-${width}-${dark ? "dark" : "light"}-${spec.type}.png`,
                                    ),
                                    fullPage: true,
                                });
                            cases++;
                        }
                    }
                    await page.evaluate(
                        (spec) =>
                            window.TokenstatChart.render(spec, {
                                reducedMotion: true,
                            }),
                        examples[0],
                    );
                    const before = await page.locator("#plot").boundingBox();
                    await page.locator("#expand").click();
                    const after = await page.locator("#plot").boundingBox();
                    assert.ok(after.height > before.height);
                    await page.locator("#expand").click();
                    // All exports must complete through the same narrow bridge used by native clients.
                    await page.evaluate(() => {
                        window.exports = [];
                        window.chrome = {
                            webview: {
                                postMessage: (message) => {
                                    if (message.type === "export")
                                        window.exports.push(message);
                                },
                            },
                        };
                    });
                    for (const format of ["json", "csv", "svg", "png"]) {
                        await page.evaluate(
                            (format) =>
                                window.TokenstatChart.exportChart(format),
                            format,
                        );
                        const item = await page.evaluate(() =>
                            window.exports.at(-1),
                        );
                        assert.equal(item.format, format);
                        assert.ok(item.content.length > 20);
                        if (format === "png")
                            assert.ok(item.content.startsWith("iVBOR"));
                        if (format === "svg") {
                            assert.ok(item.content.includes("<svg"));
                            assert.ok(
                                item.content.includes("Quarterly revenue"),
                            );
                            assert.ok(item.content.includes("Example data"));
                        }
                        if (format === "json")
                            assert.equal(JSON.parse(item.content).type, "bar");
                    }
                    // Large data stays bounded, paginates exactly, and reset restores hidden series and zoom.
                    const large = {
                        version: 1,
                        type: "bar",
                        title: "Long dataset",
                        categories: Array.from(
                            { length: 512 },
                            (_, i) => "Category " + i,
                        ),
                        series: [
                            {
                                name: "Observed",
                                data: Array.from({ length: 512 }, (_, i) =>
                                    i % 13 === 0 ? null : i - 200,
                                ),
                            },
                            {
                                name: "Forecast",
                                data: Array.from({ length: 512 }, (_, i) => i),
                            },
                        ],
                    };
                    await page.evaluate(
                        (spec) =>
                            window.TokenstatChart.render(spec, {
                                reducedMotion: true,
                            }),
                        large,
                    );
                    assert.equal(
                        await page.evaluate(
                            () => window.TokenstatChart.inspect().rows,
                        ),
                        1024,
                    );
                    assert.ok(
                        (
                            await page.evaluate(
                                () => window.TokenstatChart.inspect().zoom,
                            )
                        )[0].end < 100,
                    );
                    await page.locator("#table-toggle").click();
                    assert.equal(await page.locator("#rows tr").count(), 50);
                    await page.locator("#next").click();
                    assert.ok(
                        (await page.locator("#page").innerText()).includes("2"),
                    );
                    await page.evaluate(() =>
                        TokenstatChartEngine.echarts
                            .getInstanceByDom(document.getElementById("plot"))
                            .dispatchAction({
                                type: "legendUnSelect",
                                name: "Forecast",
                            }),
                    );
                    assert.equal(
                        (
                            await page.evaluate(
                                () => window.TokenstatChart.inspect().legend,
                            )
                        ).Forecast,
                        false,
                    );
                    await page.locator("#reset").click();
                    assert.equal(
                        (
                            await page.evaluate(
                                () => window.TokenstatChart.inspect().legend,
                            )
                        ).Forecast,
                        true,
                    );
                    assert.equal(
                        (
                            await page.evaluate(
                                () => window.TokenstatChart.inspect().zoom,
                            )
                        )[0].end,
                        100,
                    );
                    await page.locator("#table-toggle").click();
                    // Select actual SVG geometry with a pointer/touch, including the treemap's virtual root.
                    for (const type of ["bar", "pie", "treemap", "radar"]) {
                        const spec = examples.find(
                            (item) => item.type === type,
                        );
                        await page.evaluate(
                            (spec) =>
                                window.TokenstatChart.render(spec, {
                                    reducedMotion: true,
                                }),
                            spec,
                        );
                        await page.locator("#plot").scrollIntoViewIfNeeded();
                        const points = await page.evaluate(() => {
                            window.clickedChartName = null;
                            TokenstatChartEngine.echarts
                                .getInstanceByDom(
                                    document.getElementById("plot"),
                                )
                                .on("click", (event) => {
                                    window.clickedChartName = event.name;
                                    window.clickedChartEvent = {
                                        name: event.name,
                                        seriesIndex: event.seriesIndex,
                                        dataIndex: event.dataIndex,
                                    };
                                });
                            return [
                                ...document.querySelectorAll("#plot svg path"),
                            ]
                                .filter((path) => {
                                    const box = path.getBoundingClientRect(),
                                        fill = path.getAttribute("fill");
                                    return (
                                        fill &&
                                        fill !== "none" &&
                                        fill !== "transparent" &&
                                        box.width > 12 &&
                                        box.height > 12
                                    );
                                })
                                .map((path) => {
                                    const box = path.getBoundingClientRect();
                                    return {
                                        x: box.x + box.width / 2,
                                        y: box.y + box.height / 2,
                                    };
                                });
                        });
                        for (const point of points) {
                            if (point.y < 0 || point.y > 1000) continue;
                            if (width === 320)
                                await page.touchscreen.tap(point.x, point.y);
                            else await page.mouse.click(point.x, point.y);
                            if (
                                await page.evaluate(
                                    () =>
                                        !!window.TokenstatChart.inspect()
                                            .selected,
                                )
                            )
                                break;
                        }
                        // Radar polygon centers can intersect; deterministic keyboard inspection still covers every series.
                        if (type === "radar") {
                            await page.locator("#plot").focus();
                            await page.keyboard.press("ArrowRight");
                            await page.keyboard.press("ArrowRight");
                            assert.ok(
                                (
                                    await page.locator("#selection").innerText()
                                ).includes(spec.series[1].name),
                            );
                        } else {
                            assert.ok(
                                await page.locator("#selection").isVisible(),
                                name + " " + type + " pointer selection",
                            );
                            const clicked = await page.evaluate(
                                () => window.clickedChartName,
                            );
                            assert.ok(
                                (
                                    await page.locator("#selection").innerText()
                                ).includes(clicked),
                                type + " selection matches clicked category",
                            );
                            const tooltip = await page.evaluate(() =>
                                TokenstatChartEngine.echarts
                                    .getInstanceByDom(
                                        document.getElementById("plot"),
                                    )
                                    .getOption()
                                    .tooltip[0].formatter(
                                        window.clickedChartEvent,
                                    ),
                            );
                            assert.ok(
                                tooltip.includes(clicked),
                                type + " tooltip matches the hovered category",
                            );
                        }
                    }
                    const long = structuredClone(examples[0]);
                    long.title =
                        "Quarterly business performance across all regions ".repeat(
                            3,
                        );
                    long.subtitle =
                        "A detailed comparison of actual observed values and the current forecast. ".repeat(
                            6,
                        );
                    long.source = "Synthetic export fixture ".repeat(18);
                    await page.evaluate(
                        (spec) =>
                            window.TokenstatChart.render(spec, {
                                reducedMotion: true,
                            }),
                        long,
                    );
                    await page.evaluate(() =>
                        window.TokenstatChart.exportChart("svg"),
                    );
                    const svg = await page.evaluate(
                        () => window.exports.at(-1).content,
                    );
                    writeFileSync(
                        resolve(output, `${name}-${width}-long-export.svg`),
                        svg,
                    );
                    assert.ok(svg.includes("Quarterly"));
                    assert.ok(svg.includes("Synthetic"));
                    assert.ok(
                        await page.evaluate(
                            () =>
                                document
                                    .getElementById("root")
                                    .getBoundingClientRect().height <= 2200,
                        ),
                    );
                    const formulas = structuredClone(examples[0]);
                    formulas.categories[0] = "=1+1";
                    formulas.series[0].data[0] = -4;
                    await page.evaluate(
                        (spec) =>
                            window.TokenstatChart.render(spec, {
                                reducedMotion: true,
                            }),
                        formulas,
                    );
                    await page.evaluate(() =>
                        window.TokenstatChart.exportChart("csv"),
                    );
                    const csv = await page.evaluate(
                        () => window.exports.at(-1).content,
                    );
                    assert.ok(csv.includes("'=1+1"));
                    assert.ok(csv.includes('"-4"'));
                    const fractionalTick = await page.evaluate(() =>
                        TokenstatChartEngine.echarts
                            .getInstanceByDom(document.getElementById("plot"))
                            .getOption()
                            .yAxis[0].axisLabel.formatter(0.0001),
                    );
                    assert.ok(
                        fractionalTick.includes("0.0001"),
                        "small nonzero axis ticks remain nonzero",
                    );
                    const hostile = structuredClone(examples[0]);
                    hostile.title =
                        '<img src="https://invalid.example/x" onerror="window.pwned=1">';
                    hostile.categories[0] =
                        "</script><script>window.pwned=1</script>";
                    await page.evaluate(
                        (spec) =>
                            window.TokenstatChart.render(spec, {
                                reducedMotion: true,
                            }),
                        hostile,
                    );
                    assert.equal(
                        await page.evaluate(() => window.pwned),
                        undefined,
                    );
                    assert.equal(external, 0);
                    await page.evaluate(() =>
                        window.TokenstatChart.exportChart("svg"),
                    );
                    assert.ok(
                        !(
                            await page.evaluate(
                                () => window.exports.at(-1).content,
                            )
                        ).includes("<script>"),
                    );
                    await page.evaluate(
                        (spec) =>
                            window.TokenstatChart.render({
                                ...spec,
                                options: { url: "https://invalid.example" },
                            }),
                        examples[0],
                    );
                    assert.equal(
                        await page.locator("#error").isVisible(),
                        true,
                    );
                    assert.equal(
                        await page.locator("#description").isVisible(),
                        false,
                    );
                    assert.equal(await page.locator("#source").innerText(), "");
                    assert.equal(await page.title(), "Chart unavailable");
                    await page.evaluate(
                        (spec) =>
                            window.TokenstatChart.render(spec, {
                                reducedMotion: true,
                            }),
                        examples[0],
                    );
                    const exportCount = await page.evaluate(
                        () => window.exports.length,
                    );
                    await page.evaluate(async () => {
                        const exporting =
                            window.TokenstatChart.exportChart("png");
                        window.TokenstatChart.dispose();
                        await exporting;
                    });
                    assert.equal(
                        await page.evaluate(() => window.exports.length),
                        exportCount,
                        "disposing cancels an in-flight export",
                    );
                    assert.deepEqual(errors, [], name + " browser errors");
                } catch (error) {
                    await page
                        .screenshot({
                            path: resolve(
                                output,
                                `${name}-${width}-failure.png`,
                            ),
                            fullPage: true,
                        })
                        .catch(() => {});
                    throw error;
                } finally {
                    await context.close();
                }
            }
        } finally {
            await browser.close();
        }
    }
    console.log(
        `${cases} chart renders passed in Chromium and WebKit at phone, tablet and desktop widths, with themes, keyboard, touch layouts, tables, exports and hostile-input checks.`,
    );
} finally {
    server.close();
}
