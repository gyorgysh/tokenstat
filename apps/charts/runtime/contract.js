// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
(function (root) {
    "use strict";
    const kinds = [
        "bar",
        "line",
        "area",
        "pie",
        "donut",
        "scatter",
        "bubble",
        "heatmap",
        "radar",
        "funnel",
        "treemap",
        "boxplot",
    ];
    const maxBytes = 256 * 1024;
    function fail(message) {
        throw new Error(message);
    }
    function object(value, keys, name) {
        if (!value || typeof value !== "object" || Array.isArray(value))
            fail(name + " must be an object");
        if (Object.keys(value).some((key) => !keys.includes(key)))
            fail(name + " contains unsupported fields");
    }
    function label(value, max, name) {
        if (
            typeof value !== "string" ||
            /[\uD800-\uDFFF]/u.test(value) ||
            [...value].length > max ||
            /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/u.test(value)
        )
            fail(name + " is too long or contains control characters");
    }
    function number(value) {
        return (
            typeof value === "number" &&
            Number.isFinite(value) &&
            Math.abs(value) <= 1e15
        );
    }
    function validate(input) {
        const raw =
            typeof input === "string"
                ? input
                : JSON.stringify(input, (_key, value) => {
                      if (typeof value === "number" && !Number.isFinite(value))
                          fail("Numbers must be finite");
                      if (
                          ["function", "symbol", "bigint"].includes(
                              typeof value,
                          )
                      )
                          fail("Charts contain JSON data only");
                      return value;
                  });
        if (new TextEncoder().encode(raw).length > maxBytes)
            fail("A chart may contain at most 256 KiB of JSON");
        const spec = JSON.parse(raw);
        object(
            spec,
            [
                "version",
                "type",
                "title",
                "subtitle",
                "description",
                "source",
                "categories",
                "yCategories",
                "series",
                "xAxis",
                "yAxis",
                "stacked",
                "horizontal",
                "showLabels",
            ],
            "Chart",
        );
        if (spec.version !== 1)
            fail("Unsupported chart version. Use version 1");
        if (!kinds.includes(spec.type)) fail("Unsupported chart type");
        label(spec.title, 180, "Title");
        if (!spec.title.trim()) fail("A chart needs a descriptive title");
        for (const [key, max] of [
            ["subtitle", 500],
            ["description", 2000],
            ["source", 500],
        ]) {
            if (spec[key] === undefined) spec[key] = "";
            label(spec[key], max, key);
        }
        for (const key of ["stacked", "horizontal", "showLabels"]) {
            if (spec[key] === undefined) spec[key] = false;
            if (typeof spec[key] !== "boolean")
                fail(key + " must be a boolean");
        }
        for (const key of ["xAxis", "yAxis"]) {
            if (spec[key] === undefined) spec[key] = {};
            const axis = spec[key];
            object(axis, ["label", "format"], key);
            if (axis.label === undefined) axis.label = "";
            label(axis.label, 120, "Axis label");
            if (axis.format === undefined) axis.format = {};
            const format = axis.format;
            object(format, ["prefix", "suffix", "decimals"], "Number format");
            if (format.prefix === undefined) format.prefix = "";
            if (format.suffix === undefined) format.suffix = "";
            if (format.decimals === undefined) format.decimals = 2;
            label(format.prefix, 24, "Prefix");
            label(format.suffix, 24, "Suffix");
            if (
                !Number.isInteger(format.decimals) ||
                format.decimals < 0 ||
                format.decimals > 8
            )
                fail("Number precision must be between 0 and 8");
        }
        for (const key of ["categories", "yCategories"]) {
            if (spec[key] === undefined) spec[key] = [];
            const values = spec[key];
            if (!Array.isArray(values) || values.length > 512)
                fail("An axis may have at most 512 categories");
            const seen = new Set();
            for (const item of values) {
                label(item, 160, "Category");
                if (!item.trim() || seen.has(item))
                    fail("Category names must be nonempty and unique");
                seen.add(item);
            }
        }
        if (
            !Array.isArray(spec.series) ||
            !spec.series.length ||
            spec.series.length > 16
        )
            fail("A chart needs between 1 and 16 series");
        const single = [
            "pie",
            "donut",
            "funnel",
            "treemap",
            "heatmap",
        ].includes(spec.type);
        if (single && spec.series.length !== 1)
            fail("This chart needs exactly one series");
        if (spec.stacked && !["bar", "line", "area"].includes(spec.type))
            fail("Stacking is supported for bar, line and area charts");
        if (spec.horizontal && spec.type !== "bar")
            fail("Horizontal orientation is supported for bar charts");
        if (spec.type !== "heatmap" && spec.yCategories.length)
            fail("yCategories belongs to heatmaps");
        const xy = ["scatter", "bubble"].includes(spec.type);
        if (xy && spec.categories.length)
            fail(
                "Scatter and bubble charts use numeric coordinates, without categories",
            );
        if (!xy && !spec.categories.length)
            fail("This chart needs category labels");
        if (
            spec.type === "radar" &&
            (spec.categories.length < 3 || spec.categories.length > 12)
        )
            fail("Radar charts need between 3 and 12 categories");
        if (spec.type === "heatmap" && !spec.yCategories.length)
            fail("Heatmaps need yCategories");
        const names = new Set();
        let count = 0,
            observations = 0;
        for (const series of spec.series) {
            object(series, ["name", "data"], "Series");
            label(series.name, 160, "Series name");
            if (!series.name.trim() || names.has(series.name))
                fail("Series names must be nonempty and unique");
            names.add(series.name);
            if (!Array.isArray(series.data) || !series.data.length)
                fail("A series needs data");
            count += series.data.length;
            if (count > 10000) fail("A chart may have at most 10000 points");
            if (
                !xy &&
                spec.type !== "heatmap" &&
                series.data.length !== spec.categories.length
            )
                fail(
                    "Each series must have one value for every category. Use null for missing observations",
                );
            let positive = false;
            const cells = new Set();
            for (const point of series.data) {
                if (xy || ["heatmap", "boxplot"].includes(spec.type)) {
                    observations++;
                    const width =
                        spec.type === "scatter"
                            ? 2
                            : spec.type === "boxplot"
                              ? 5
                              : 3;
                    if (
                        !Array.isArray(point) ||
                        point.length !== width ||
                        !point.every(number)
                    )
                        fail(
                            "This chart requires numeric coordinate arrays of length " +
                                width,
                        );
                    if (spec.type === "bubble" && point[2] <= 0)
                        fail("Bubble sizes must be positive");
                    if (
                        spec.type === "boxplot" &&
                        point.some((v, i) => i && point[i - 1] > v)
                    )
                        fail(
                            "Boxplot values must be ordered: minimum, Q1, median, Q3, maximum",
                        );
                    if (spec.type === "heatmap") {
                        if (
                            !Number.isInteger(point[0]) ||
                            !Number.isInteger(point[1]) ||
                            point[0] < 0 ||
                            point[1] < 0 ||
                            point[0] >= spec.categories.length ||
                            point[1] >= spec.yCategories.length
                        )
                            fail(
                                "Heatmap coordinates must index categories and yCategories",
                            );
                        const key = point[0] + ":" + point[1];
                        if (cells.has(key))
                            fail("Heatmap cells must have unique coordinates");
                        cells.add(key);
                    }
                } else if (point !== null) {
                    observations++;
                    if (!number(point))
                        fail(
                            "Values must be finite numbers between -1e15 and 1e15, or null",
                        );
                    if (
                        ["pie", "donut", "funnel", "treemap", "radar"].includes(
                            spec.type,
                        ) &&
                        point < 0
                    )
                        fail(
                            "This chart type cannot represent negative values",
                        );
                    positive ||= point > 0;
                } else if (
                    ["pie", "donut", "funnel", "treemap", "radar"].includes(
                        spec.type,
                    )
                )
                    fail("This chart type needs a number for every category");
            }
            if (
                ["pie", "donut", "funnel", "treemap"].includes(spec.type) &&
                !positive
            )
                fail("This chart needs at least one positive value");
        }
        if (!observations)
            fail("A chart needs at least one numeric observation");
        if (new TextEncoder().encode(JSON.stringify(spec)).length > maxBytes)
            fail("The normalized chart exceeds 256 KiB");
        return spec;
    }
    function fence(input) {
        return (
            "```tokenstat-chart\n" + JSON.stringify(validate(input)) + "\n```"
        );
    }
    const api = Object.freeze({ kinds, validate, fence, maxBytes });
    root.TokenstatCharts = api;
    if (typeof module !== "undefined" && module.exports) module.exports = api;
})(globalThis);
