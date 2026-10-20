// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { validate, fence, kinds } = require("../runtime/contract.js");
const examples = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../examples.json")),
);
const invalid = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../invalid.json")),
);
for (const spec of examples)
    test("valid " + spec.type, () => {
        const result = validate(spec);
        assert.equal(result.type, spec.type);
        const markdown = fence(spec);
        assert.ok(markdown.startsWith("```tokenstat-chart\n"));
        assert.deepEqual(validate(markdown.split("\n")[1]), result);
    });
for (const { name, spec } of invalid)
    test("rejects " + name, () => assert.throws(() => validate(spec)));
test("examples cover exactly the advertised families", () =>
    assert.deepEqual(
        examples.map((x) => x.type),
        kinds,
    ));
test("validates before truncation or rendering", () => {
    assert.throws(() => validate(" ".repeat(256 * 1024 + 1)));
    assert.throws(() =>
        validate({
            ...examples[5],
            series: [
                {
                    name: "Points",
                    data: Array.from({ length: 10001 }, () => [1, 2]),
                },
            ],
        }),
    );
    assert.throws(() => validate({ ...examples[0], categories: null }));
    assert.throws(() =>
        validate('{"version":1,"__proto__":{"polluted":true}}'),
    );
    assert.equal({}.polluted, undefined);
});
test("untrusted labels remain data", () => {
    const input = structuredClone(examples[0]);
    input.title = "<img src=x onerror=alert(1)>";
    input.categories[0] = "</script><script>alert(1)</script>";
    assert.equal(validate(input).title, input.title);
});
test("JavaScript SDK uses the same contract", () =>
    assert.equal(
        require("../sdk/index.cjs").chart(examples[0]),
        fence(examples[0]),
    ));

test("JavaScript inputs never silently turn non-finite numbers into missing data", () => {
    const spec = structuredClone(examples[0]);
    spec.series[0].data[0] = NaN;
    assert.throws(() => validate(spec));
    spec.series[0].data[0] = Infinity;
    assert.throws(() => validate(spec));
});
