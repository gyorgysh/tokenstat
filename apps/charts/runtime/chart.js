// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
(function () {
    "use strict";
    const $ = (id) => document.getElementById(id);
    let chart,
        spec,
        rows = [],
        columns = [],
        selected = null,
        page = 0,
        disposed = false;
    let locale = "en",
        dark = false,
        expanded = false,
        lastHeight = 0;
    let words = {},
        fontsReady = false,
        pendingRender = null;
    document.fonts
        .load("13px Manrope")
        .catch(() => [])
        .then(() => {
            fontsReady = true;
            if (pendingRender) {
                const [input, settings] = pendingRender;
                pendingRender = null;
                render(input, settings);
            }
        });
    const defaults = {
        chart: "Chart",
        data: "Data",
        reset: "Reset",
        expand: "Expand",
        collapse: "Collapse",
        copy: "Copy selection",
        export: "Export",
        choose: "Choose format",
        png: "PNG image",
        svg: "SVG image",
        csv: "CSV data",
        json: "Chart JSON",
        previous: "Previous",
        next: "Next",
        series: "Series",
        category: "Category",
        value: "Value",
        missing: "Missing",
        minimum: "Minimum",
        q1: "Q1",
        median: "Median",
        q3: "Q3",
        maximum: "Maximum",
        size: "Size",
        source: "Source",
        page: "Page",
        of: "of",
        copied: "Selection copied",
        exported: "Export ready",
        unavailable: "Chart unavailable",
        inspect:
            "Interactive chart. Use arrow keys to inspect values, Enter to select, and Escape to clear.",
        empty: "No data",
        loading: "Preparing chart",
    };
    function t(key) {
        return words[key] || defaults[key] || key;
    }
    function host(message) {
        if (disposed) return false;
        try {
            if (window.webkit?.messageHandlers?.chart)
                window.webkit.messageHandlers.chart.postMessage(message);
            else if (window.chrome?.webview)
                window.chrome.webview.postMessage(message);
            else if (window.TokenstatChartHost)
                window.TokenstatChartHost.postMessage(JSON.stringify(message));
            else return false;
            return true;
        } catch {
            return false;
        }
    }
    function measure() {
        const height = Math.min(
            2200,
            Math.max(180, Math.ceil($("root").getBoundingClientRect().height)),
        );
        if (height !== lastHeight) {
            lastHeight = height;
            host({ type: "height", height });
        }
    }
    function localized(value, decimals = 8) {
        try {
            return new Intl.NumberFormat(
                locale,
                value !== 0 && Math.abs(value) < Math.pow(10, -decimals)
                    ? { notation: "scientific", maximumSignificantDigits: 8 }
                    : { maximumFractionDigits: decimals },
            ).format(value);
        } catch {
            return String(value);
        }
    }
    function numeric(value, axis = "yAxis") {
        if (value === null || value === undefined) return t("missing");
        const format = spec[axis].format;
        return (
            format.prefix + localized(value, format.decimals) + format.suffix
        );
    }
    function compact(value) {
        if (value !== 0 && Math.abs(value) < 1) return localized(value, 8);
        try {
            return new Intl.NumberFormat(locale, {
                notation: "compact",
                maximumFractionDigits: 1,
            }).format(value);
        } catch {
            return String(value);
        }
    }
    function colors() {
        return dark
            ? [
                  "#b69aea",
                  "#64c8bf",
                  "#e4b66d",
                  "#e28b9e",
                  "#85b9ef",
                  "#c996d8",
                  "#a6c883",
                  "#cfa38a",
              ]
            : [
                  "#7853b5",
                  "#187f78",
                  "#9d640d",
                  "#b53b60",
                  "#326ca9",
                  "#9654a4",
                  "#527b28",
                  "#966646",
              ];
    }
    function buildRows() {
        const type = spec.type;
        if (type === "radar") {
            columns = [t("series"), ...spec.categories];
            rows = spec.series.map((series, si) => ({
                cells: [series.name, ...series.data],
                si,
                di: 0,
            }));
            return;
        }
        if (["scatter", "bubble"].includes(type))
            columns = [
                t("series"),
                spec.xAxis.label || "X",
                spec.yAxis.label || "Y",
                ...(type === "bubble" ? [t("size")] : []),
            ];
        else if (type === "heatmap")
            columns = [
                spec.xAxis.label || "X",
                spec.yAxis.label || "Y",
                t("value"),
            ];
        else if (type === "boxplot")
            columns = [
                t("series"),
                t("category"),
                t("minimum"),
                t("q1"),
                t("median"),
                t("q3"),
                t("maximum"),
            ];
        else
            columns = [
                t("series"),
                spec.xAxis.label || t("category"),
                spec.yAxis.label || t("value"),
            ];
        rows = [];
        spec.series.forEach((series, si) =>
            series.data.forEach((value, di) => {
                let cells;
                if (["scatter", "bubble"].includes(type))
                    cells = [series.name, ...value];
                else if (type === "heatmap")
                    cells = [
                        spec.categories[value[0]],
                        spec.yCategories[value[1]],
                        value[2],
                    ];
                else if (type === "boxplot")
                    cells = [series.name, spec.categories[di], ...value];
                else cells = [series.name, spec.categories[di], value];
                rows.push({ cells, si, di });
            }),
        );
    }
    function selectedText(row) {
        return row.cells
            .map(
                (value, i) =>
                    columns[i] +
                    ": " +
                    (typeof value === "number"
                        ? spec.type === "bubble" && i === 3
                            ? localized(value)
                            : numeric(
                                  value,
                                  ["scatter", "bubble"].includes(spec.type) &&
                                      i === 1
                                      ? "xAxis"
                                      : "yAxis",
                              )
                        : value === null
                          ? t("missing")
                          : value),
            )
            .join("\n");
    }
    function rowForEvent(event) {
        if (spec.type === "radar")
            return rows.find((row) => row.si === event.dataIndex);
        if (["pie", "donut", "funnel", "treemap"].includes(spec.type)) {
            const category = spec.categories.indexOf(event.name);
            return rows.find((row) => row.di === category);
        }
        return rows.find(
            (row) => row.si === event.seriesIndex && row.di === event.dataIndex,
        );
    }
    function select(si, di) {
        const row = rows.find((row) => row.si === si && row.di === di);
        if (!row) return;
        selected = row;
        $("selection").textContent = selectedText(row);
        $("selection").hidden = false;
        $("copy").hidden = false;
        chart.dispatchAction({ type: "downplay" });
        const target = ["pie", "donut", "funnel", "treemap"].includes(spec.type)
            ? { name: spec.categories[di] }
            : { dataIndex: spec.type === "radar" ? si : di };
        chart.dispatchAction({
            type: "highlight",
            seriesIndex: spec.type === "radar" ? 0 : si,
            ...target,
        });
        measure();
    }
    function axisBase() {
        const line = dark ? "#41414f" : "#dedfe8",
            muted = dark ? "#bbbaca" : "#656575";
        return {
            nameTextStyle: { color: muted, fontSize: 12 },
            axisLabel: {
                color: muted,
                fontSize: 12,
                hideOverlap: true,
                overflow: "truncate",
                width: Math.min(140, (chart?.getWidth() || 500) * 0.28),
            },
            axisLine: { lineStyle: { color: line } },
            axisTick: { show: false },
            splitLine: { lineStyle: { color: line, opacity: 0.5 } },
        };
    }
    function options(reducedMotion) {
        const type = spec.type,
            palette = colors();
        const base = {
            color: palette,
            backgroundColor: "transparent",
            animation: !reducedMotion,
            animationDuration: 250,
            animationDurationUpdate: 180,
            textStyle: {
                fontFamily:
                    "Manrope, -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, sans-serif",
                color: dark ? "#ededf4" : "#24232c",
            },
            aria: {
                enabled: true,
                label: { description: spec.title + ". " + spec.description },
                decal: { show: palette.length < spec.series.length },
            },
            tooltip: {
                trigger: "item",
                confine: true,
                renderMode: "richText",
                backgroundColor: dark ? "#2c293a" : "#ffffff",
                borderColor: dark ? "#555065" : "#dbd7e5",
                textStyle: {
                    color: dark ? "#f1eef7" : "#26222e",
                    fontSize: 12,
                },
                formatter: (p) => {
                    const row = rowForEvent(p);
                    return row ? selectedText(row) : "";
                },
            },
            legend: {
                type: "scroll",
                top: 0,
                left: 0,
                right: 0,
                textStyle: {
                    color: dark ? "#d7d3e4" : "#514b5e",
                    fontSize: 12,
                },
                itemWidth: 12,
                itemHeight: 8,
                pageTextStyle: { color: dark ? "#d7d3e4" : "#514b5e" },
            },
            series: [],
        };
        const pointSeries = spec.series.map((s, i) => ({
            name: s.name,
            data: s.data,
            label: {
                show: spec.showLabels,
                color: dark ? "#eeedf5" : "#28252e",
                fontSize: 11,
            },
            emphasis: { focus: "none" },
            lineStyle: { width: 2, type: i >= 8 ? "dashed" : "solid" },
            itemStyle: { borderRadius: type === "bar" ? 3 : 0 },
        }));
        if (["pie", "donut", "funnel", "treemap"].includes(type)) {
            const data = spec.categories.map((name, i) => ({
                name,
                value: spec.series[0].data[i],
            }));
            base.legend.show = type !== "treemap";
            if (type === "pie" || type === "donut")
                base.series = [
                    {
                        type: "pie",
                        name: spec.series[0].name,
                        data,
                        radius: type === "donut" ? ["45%", "70%"] : "70%",
                        center: ["50%", "57%"],
                        avoidLabelOverlap: true,
                        label: {
                            show: spec.showLabels,
                            formatter: "{b}",
                            color: base.textStyle.color,
                        },
                        labelLine: { show: spec.showLabels },
                        emphasis: { scale: true, scaleSize: 5 },
                    },
                ];
            else if (type === "funnel")
                base.series = [
                    {
                        type: "funnel",
                        name: spec.series[0].name,
                        data,
                        top: 42,
                        bottom: 12,
                        left: "15%",
                        width: "70%",
                        sort: "none",
                        gap: 3,
                        label: {
                            show: true,
                            position: "inside",
                            color: dark ? "#1b1a25" : "#ffffff",
                            formatter: "{b}",
                            fontSize: 12,
                        },
                    },
                ];
            else
                base.series = [
                    {
                        type: "treemap",
                        name: spec.series[0].name,
                        data,
                        top: 8,
                        bottom: 8,
                        left: 0,
                        right: 0,
                        roam: false,
                        nodeClick: false,
                        breadcrumb: { show: false },
                        label: {
                            show: true,
                            formatter: "{b}",
                            fontSize: 12,
                            color: dark ? "#1b1a25" : "#ffffff",
                        },
                        itemStyle: { gapWidth: 3, borderWidth: 0 },
                    },
                ];
        } else if (type === "radar") {
            const max = Math.max(1, ...spec.series.flatMap((s) => s.data));
            base.radar = {
                indicator: spec.categories.map((name) => ({
                    name,
                    max: max * 1.1,
                })),
                center: ["50%", "57%"],
                radius: "64%",
                axisName: { color: base.textStyle.color, fontSize: 11 },
                splitArea: { show: false },
                splitLine: {
                    lineStyle: { color: dark ? "#44404f" : "#e3dfeb" },
                },
            };
            base.series = [
                {
                    type: "radar",
                    data: spec.series.map((s, i) => ({
                        name: s.name,
                        value: s.data,
                        lineStyle: {
                            color: palette[i % palette.length],
                            width: 2,
                        },
                        areaStyle: { opacity: 0.06 },
                        symbolSize: 5,
                    })),
                },
            ];
        } else {
            const xy = ["scatter", "bubble"].includes(type),
                heat = type === "heatmap";
            const cat = {
                ...axisBase(),
                type: "category",
                data: spec.categories,
                name: spec.xAxis.label,
                nameLocation: "middle",
                nameGap: 35,
                boundaryGap: type === "bar" || type === "boxplot" || heat,
                splitLine: { show: false },
            };
            const val = {
                ...axisBase(),
                type: "value",
                name: spec.yAxis.label,
                nameGap: 18,
                axisLabel: {
                    ...axisBase().axisLabel,
                    formatter: (value) =>
                        spec.yAxis.format.prefix +
                        compact(value) +
                        spec.yAxis.format.suffix,
                },
                scale: xy,
            };
            base.grid = {
                left: 14,
                right: 22,
                top: spec.series.length > 1 ? 62 : 42,
                bottom: spec.categories.length > 16 || xy ? 72 : 45,
                containLabel: true,
            };
            base.legend.show = spec.series.length > 1;
            if (xy) {
                base.xAxis = {
                    ...val,
                    name: spec.xAxis.label,
                    nameLocation: "middle",
                    nameGap: 30,
                    axisLabel: {
                        ...val.axisLabel,
                        formatter: (value) =>
                            spec.xAxis.format.prefix +
                            compact(value) +
                            spec.xAxis.format.suffix,
                    },
                };
                base.yAxis = val;
            } else if (heat) {
                base.xAxis = cat;
                base.yAxis = {
                    ...cat,
                    data: spec.yCategories,
                    name: spec.yAxis.label,
                    nameLocation: "end",
                    nameGap: 14,
                };
                const values = spec.series[0].data.map((p) => p[2]);
                let min = Math.min(...values),
                    max = Math.max(...values);
                if (min === max) {
                    min -= 1;
                    max += 1;
                }
                base.visualMap = {
                    min,
                    max,
                    orient: "horizontal",
                    left: "center",
                    bottom: 0,
                    calculable: false,
                    text: [compact(max), compact(min)],
                    textStyle: { color: base.textStyle.color },
                    inRange: {
                        color: dark
                            ? ["#282238", "#76539f", "#d7b5ff"]
                            : ["#eee6fa", "#9670c3", "#523076"],
                    },
                };
                base.grid.bottom = spec.xAxis.label ? 80 : 62;
            } else if (spec.horizontal) {
                base.xAxis = { ...val, nameLocation: "middle", nameGap: 30 };
                base.yAxis = {
                    ...cat,
                    inverse: true,
                    nameLocation: "end",
                    nameGap: 12,
                };
            } else {
                base.xAxis = cat;
                base.yAxis = val;
            }
            const sizeMax =
                type === "bubble"
                    ? Math.max(
                          ...spec.series.flatMap((s) =>
                              s.data.map((p) => p[2]),
                          ),
                      )
                    : 1;
            base.series = pointSeries.map((s) => ({
                ...s,
                type: ["area", "line"].includes(type)
                    ? "line"
                    : xy
                      ? "scatter"
                      : type,
                stack: spec.stacked ? "total" : undefined,
                areaStyle: type === "area" ? { opacity: 0.16 } : undefined,
                connectNulls: false,
                showSymbol: spec.categories.length <= 40,
                symbolSize:
                    type === "bubble"
                        ? (v) => Math.max(6, Math.sqrt(v[2] / sizeMax) * 42)
                        : xy
                          ? 9
                          : 5,
                label: {
                    ...s.label,
                    position: spec.horizontal ? "right" : "top",
                },
                barMaxWidth: 42,
            }));
            if (spec.categories.length > 16 || xy) {
                const axis = spec.horizontal ? "yAxisIndex" : "xAxisIndex";
                base.dataZoom = [
                    {
                        type: "slider",
                        orient: "horizontal",
                        [axis]: 0,
                        bottom: 2,
                        height: 18,
                        start: 0,
                        end:
                            type === "bar" && spec.categories.length > 32
                                ? (32 / spec.categories.length) * 100
                                : 100,
                        brushSelect: false,
                        showDataShadow: false,
                        borderColor: dark ? "#51475f" : "#ded7e9",
                        fillerColor: dark
                            ? "rgba(182,154,234,.17)"
                            : "rgba(120,83,181,.13)",
                        handleStyle: { color: palette[0] },
                    },
                    {
                        type: "inside",
                        [axis]: 0,
                        zoomOnMouseWheel: "ctrl",
                        moveOnMouseWheel: false,
                        preventDefaultMouseMove: false,
                    },
                ];
                if (heat) {
                    base.visualMap.bottom = 30;
                    base.grid.bottom = 110;
                }
            }
        }
        base.legend.data = ["pie", "donut", "funnel", "treemap"].includes(type)
            ? spec.categories
            : spec.series.map((s) => s.name);
        return base;
    }
    function table() {
        $("columns").replaceChildren();
        $("rows").replaceChildren();
        const header = document.createElement("tr");
        for (const name of columns) {
            const th = document.createElement("th");
            th.scope = "col";
            th.textContent = name;
            header.append(th);
        }
        $("columns").append(header);
        for (const row of rows.slice(page * 50, (page + 1) * 50)) {
            const tr = document.createElement("tr");
            row.cells.forEach((value) => {
                const td = document.createElement("td");
                td.textContent =
                    value === null
                        ? t("missing")
                        : typeof value === "number"
                          ? localized(value)
                          : value;
                if (typeof value === "number") td.className = "numeric";
                tr.append(td);
            });
            $("rows").append(tr);
        }
        const pages = Math.max(1, Math.ceil(rows.length / 50));
        $("page").textContent =
            t("page") + " " + (page + 1) + " " + t("of") + " " + pages;
        $("previous").disabled = page === 0;
        $("next").disabled = page + 1 >= pages;
        $("pagination").hidden = pages <= 1;
        $("caption").textContent =
            spec.title + " · " + rows.length + " " + t("data").toLowerCase();
        measure();
    }
    function csvCell(value) {
        let text = value === null ? "" : String(value);
        // Spreadsheets interpret leading formulas on import, even inside CSV quotes.
        if (typeof value !== "number" && /^[\s]*[=+@-]/u.test(text))
            text = "'" + text;
        return '"' + text.replace(/"/g, '""') + '"';
    }
    function filename(extension) {
        return "chart." + extension;
    }
    function wrapText(text, width, font) {
        const context = document.createElement("canvas").getContext("2d");
        context.font = font;
        const lines = [];
        let line = "";
        for (const char of text) {
            if (char === "\n") {
                lines.push(line);
                line = "";
                continue;
            }
            if (line && context.measureText(line + char).width > width) {
                lines.push(line);
                line = "";
            }
            line += char;
        }
        if (line) lines.push(line);
        return lines.join("\n");
    }
    async function exportChart(format) {
        if (!spec || !chart || !["json", "csv", "svg", "png"].includes(format))
            throw new Error(t("unavailable"));
        let content,
            mime,
            base64 = false;
        if (format === "json") {
            content = JSON.stringify(spec, null, 2) + "\n";
            mime = "application/json";
        } else if (format === "csv") {
            content =
                "\uFEFF" +
                [columns, ...rows.map((row) => row.cells)]
                    .map((row) => row.map(csvCell).join(","))
                    .join("\r\n") +
                "\r\n";
            mime = "text/csv";
        } else {
            // Export the visible chart together with title, source, and current series selection.
            const width = Math.min(1600, Math.max(720, chart.getWidth()));
            const title = wrapText(spec.title, width - 40, "600 18px Manrope"),
                subtitle = wrapText(spec.subtitle, width - 40, "12px Manrope");
            const source = wrapText(
                spec.source ? t("source") + ": " + spec.source : "",
                width - 40,
                "12px Manrope",
            );
            const heading =
                28 +
                title.split("\n").length * 24 +
                (subtitle ? subtitle.split("\n").length * 18 + 8 : 0);
            const footer = source ? source.split("\n").length * 17 + 24 : 20,
                height = heading + 420 + footer;
            const element = document.createElement("div");
            element.style.cssText =
                "position:fixed;left:-10000px;width:" +
                width +
                "px;height:" +
                height +
                "px";
            document.body.append(element);
            const imageChart = TokenstatChartEngine.echarts.init(
                element,
                null,
                { renderer: "svg", width, height },
            );
            try {
                const option = options(true);
                option.backgroundColor = dark ? "#1b1a25" : "#ffffff";
                option.title = {
                    text: title,
                    subtext: subtitle,
                    textStyle: {
                        ...option.textStyle,
                        fontSize: 18,
                        lineHeight: 24,
                    },
                    subtextStyle: {
                        color: dark ? "#c1b9d0" : "#67606f",
                        fontSize: 12,
                        lineHeight: 18,
                    },
                    left: 20,
                    top: 12,
                };
                option.legend = {
                    ...option.legend,
                    top: heading,
                    selected: chart.getOption().legend?.[0]?.selected,
                };
                if (option.grid)
                    option.grid = {
                        ...option.grid,
                        top: heading + 62,
                        bottom: footer + 50,
                    };
                option.graphic = [
                    {
                        type: "text",
                        left: 20,
                        bottom: 12,
                        style: {
                            text: source,
                            fontFamily: "Manrope, sans-serif",
                            lineHeight: 17,
                            fill: dark ? "#c1b9d0" : "#67606f",
                            fontSize: 12,
                        },
                    },
                ];
                if (option.radar)
                    option.radar = {
                        ...option.radar,
                        center: [width / 2, heading + 220],
                        radius: 150,
                    };
                if (["pie", "donut"].includes(spec.type))
                    option.series[0] = {
                        ...option.series[0],
                        center: [width / 2, heading + 220],
                        radius: spec.type === "donut" ? [90, 160] : 160,
                    };
                if (["funnel", "treemap"].includes(spec.type))
                    option.series[0] = {
                        ...option.series[0],
                        top: heading + 40,
                        bottom: footer,
                    };
                if (option.visualMap) {
                    const zoomed = !!option.dataZoom?.length;
                    option.visualMap.bottom = footer + (zoomed ? 30 : 0);
                    option.grid.bottom = footer + (zoomed ? 120 : 90);
                }
                const zoom = chart.getOption().dataZoom || [];
                option.dataZoom = (option.dataZoom || []).map((item, i) => ({
                    ...item,
                    bottom: item.type === "slider" ? footer : undefined,
                    start: zoom[i]?.start ?? item.start,
                    end: zoom[i]?.end ?? item.end,
                }));
                imageChart.setOption(option);
                const svg = imageChart.renderToSVGString();
                if (format === "svg") {
                    content = svg;
                    mime = "image/svg+xml";
                } else {
                    const img = new Image();
                    img.src =
                        "data:image/svg+xml;charset=utf-8," +
                        encodeURIComponent(svg);
                    await img.decode();
                    const canvas = document.createElement("canvas");
                    canvas.width = width * 2;
                    canvas.height = height * 2;
                    const context = canvas.getContext("2d");
                    if (!context) throw new Error("Image export unavailable");
                    context.drawImage(img, 0, 0, canvas.width, canvas.height);
                    content = canvas.toDataURL("image/png").split(",")[1];
                    mime = "image/png";
                    base64 = true;
                }
            } finally {
                imageChart.dispose();
                element.remove();
            }
        }
        if (disposed) return;
        if (
            new TextEncoder().encode(content).length >
            (base64 ? Math.ceil((8 * 1024 * 1024 * 4) / 3) : 8 * 1024 * 1024)
        )
            throw new Error(t("unavailable"));
        if (
            !host({
                type: "export",
                format,
                mime,
                name: filename(format),
                content,
                base64,
            })
        ) {
            const bytes = base64
                ? Uint8Array.from(atob(content), (c) => c.charCodeAt(0))
                : content;
            const url = URL.createObjectURL(new Blob([bytes], { type: mime })),
                a = document.createElement("a");
            a.href = url;
            a.download = filename(format);
            a.click();
            setTimeout(() => URL.revokeObjectURL(url), 1000);
        }
        $("status").textContent = t("exported");
        measure();
    }
    function labels() {
        const buttons = {
            "table-toggle": ["▦", "data"],
            reset: ["↺", "reset"],
            expand: ["⛶", expanded ? "collapse" : "expand"],
            copy: ["⧉", "copy"],
        };
        for (const [id, [icon, key]] of Object.entries(buttons)) {
            const glyph = document.createElement("span");
            glyph.textContent = icon;
            glyph.setAttribute("aria-hidden", "true");
            $(id).replaceChildren(glyph, document.createTextNode(" " + t(key)));
        }
        $("previous").textContent = "← " + t("previous");
        $("next").textContent = t("next") + " →";
        const select = $("export");
        select.setAttribute("aria-label", t("export"));
        for (const option of select.options)
            option.textContent = t(option.value || "choose");
        select.parentNode.firstChild.textContent = t("export") + " ";
        $("plot").setAttribute("aria-label", t("inspect"));
        $("instructions").textContent = t("inspect");
        document
            .querySelector(".toolbar")
            .setAttribute("aria-label", t("chart"));
        $("pagination").setAttribute("aria-label", t("data") + " " + t("page"));
        $("data-panel").setAttribute("aria-label", t("data"));
    }
    function render(input, settings = {}) {
        if (disposed) return;
        if (!fontsReady) {
            pendingRender = [input, settings];
            return;
        }
        words = settings.strings || {};
        dark =
            settings.dark ?? matchMedia("(prefers-color-scheme:dark)").matches;
        try {
            locale = Intl.getCanonicalLocales(
                settings.locale || navigator.language || "en",
            )[0];
        } catch {
            locale = "en";
        }
        document.documentElement.lang = locale;
        document.documentElement.style.colorScheme = dark ? "dark" : "light";
        const theme = dark
            ? {
                  "--bg": "#1b1a25",
                  "--fg": "#ededf4",
                  "--muted": "#b7b2c3",
                  "--line": "#3d3749",
                  "--soft": "#272330",
                  "--accent": "#b69aea",
                  "--focus": "#cbb0f4",
              }
            : {};
        for (const key of [
            "--bg",
            "--fg",
            "--muted",
            "--line",
            "--soft",
            "--accent",
            "--focus",
        ])
            document.documentElement.style.removeProperty(key);
        for (const [key, value] of Object.entries(theme))
            document.documentElement.style.setProperty(key, value);
        try {
            spec = TokenstatCharts.validate(input);
            buildRows();
            selected = null;
            page = 0;
            $("data-panel").hidden = true;
            $("table-toggle").setAttribute("aria-expanded", "false");
            document.querySelector(".toolbar").hidden = false;
            $("title").textContent = spec.title;
            document.title = spec.title;
            for (const key of ["subtitle", "description"]) {
                $(key).textContent = spec[key];
                $(key).hidden = !spec[key];
            }
            $("kind").textContent = "";
            $("source").textContent = spec.source
                ? t("source") + ": " + spec.source
                : "";
            $("error").hidden = true;
            $("plot").hidden = false;
            $("selection").hidden = true;
            $("copy").hidden = true;
            $("status").textContent = "";
            labels();
            if (chart) chart.dispose();
            chart = TokenstatChartEngine.echarts.init($("plot"), null, {
                renderer: "svg",
            });
            chart.setOption(
                options(
                    settings.reducedMotion ??
                        matchMedia("(prefers-reduced-motion:reduce)").matches,
                ),
            );
            chart.on("click", (event) => {
                const row = rowForEvent(event);
                if (row) select(row.si, row.di);
            });
            table();
            $("root").setAttribute("aria-busy", "false");
            host({ type: "ready", version: 1 });
            measure();
        } catch (error) {
            if (chart) {
                chart.dispose();
                chart = null;
            }
            spec = null;
            rows = [];
            selected = null;
            $("data-panel").hidden = true;
            $("selection").hidden = true;
            document.querySelector(".toolbar").hidden = true;
            $("title").textContent = t("unavailable");
            document.title = t("unavailable");
            for (const key of ["subtitle", "description"]) {
                $(key).hidden = true;
                $(key).textContent = "";
            }
            $("source").textContent = "";
            $("status").textContent = "";
            $("error").textContent = error.message;
            $("error").hidden = false;
            $("plot").hidden = true;
            $("root").setAttribute("aria-busy", "false");
            host({
                type: "error",
                message: String(error.message).slice(0, 400),
            });
            measure();
        }
    }
    $("table-toggle").onclick = () => {
        const visible = $("data-panel").hidden;
        $("data-panel").hidden = !visible;
        $("table-toggle").setAttribute("aria-expanded", String(visible));
        if (visible) table();
        measure();
    };
    $("previous").onclick = () => {
        page = Math.max(0, page - 1);
        table();
    };
    $("next").onclick = () => {
        page = Math.min(Math.ceil(rows.length / 50) - 1, page + 1);
        table();
    };
    $("reset").onclick = () => {
        if (!chart) return;
        chart.dispatchAction({ type: "dataZoom", start: 0, end: 100 });
        const names = chart.getOption().legend?.[0]?.data || [];
        for (const name of names)
            chart.dispatchAction({
                type: "legendSelect",
                name: typeof name === "string" ? name : name.name,
            });
        chart.dispatchAction({ type: "downplay" });
        selected = null;
        $("selection").hidden = true;
        $("copy").hidden = true;
        measure();
    };
    $("expand").onclick = () => {
        expanded = !expanded;
        $("root").classList.toggle("expanded", expanded);
        $("expand").setAttribute("aria-pressed", String(expanded));
        labels();
        chart?.resize();
        measure();
    };
    $("copy").onclick = async () => {
        if (!selected) return;
        const text = spec.title + "\n" + selectedText(selected);
        if (!host({ type: "copy", text })) {
            try {
                await navigator.clipboard.writeText(text);
            } catch {}
        }
        $("status").textContent = t("copied");
        measure();
    };
    $("export").onchange = async (event) => {
        const format = event.target.value;
        event.target.value = "";
        if (!format || !spec) return;
        try {
            await exportChart(format);
        } catch (error) {
            $("status").textContent = error.message;
            measure();
        }
    };
    $("plot").onkeydown = (event) => {
        if (!chart || !rows.length) return;
        let index = selected ? rows.indexOf(selected) : -1;
        if (
            [
                "ArrowRight",
                "ArrowDown",
                "ArrowLeft",
                "ArrowUp",
                "Enter",
                "Escape",
            ].includes(event.key)
        )
            event.preventDefault();
        if (event.key === "Escape") {
            chart.dispatchAction({ type: "downplay" });
            selected = null;
            $("selection").hidden = true;
            $("copy").hidden = true;
            measure();
        } else if (event.key === "Enter") {
            index = Math.max(0, index);
            select(rows[index].si, rows[index].di);
        } else if (["ArrowRight", "ArrowDown"].includes(event.key)) {
            index = (index + 1) % rows.length;
            select(rows[index].si, rows[index].di);
        } else if (["ArrowLeft", "ArrowUp"].includes(event.key)) {
            index =
                index < 0
                    ? rows.length - 1
                    : (index - 1 + rows.length) % rows.length;
            select(rows[index].si, rows[index].di);
        }
    };
    const observer = new ResizeObserver(() => {
        chart?.resize();
        measure();
    });
    observer.observe($("root"));
    observer.observe($("plot"));
    window.TokenstatChart = Object.freeze({
        render,
        dispose() {
            disposed = true;
            observer.disconnect();
            chart?.dispose();
            chart = null;
        },
        exportChart,
        inspect() {
            return {
                valid: !!chart,
                rows: rows.length,
                selected: selected ? selectedText(selected) : null,
                legend: chart?.getOption().legend?.[0]?.selected || {},
                expanded,
                zoom:
                    chart?.getOption().dataZoom?.map((item) => ({
                        start: item.start,
                        end: item.end,
                    })) || [],
            };
        },
    });
    host({ type: "loaded" });
    measure();
})();
