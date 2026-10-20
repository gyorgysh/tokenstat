# Interactive charts in chat

Every chat client uses the same bundled Apache ECharts renderer. Charts work
without a connection and stay in the conversation when it is reopened or read
from another approved device. Chart data is part of the private conversation,
not the aggregate usage archive or account upload.

Agents present a chart by including a complete `tokenstat-chart` JSON fence in
an assistant reply. A fence still being written shows a preparing state. Invalid
charts show an explanation, without executing the input or fetching resources.

```tokenstat-chart
{"version":1,"type":"bar","title":"Revenue by quarter","categories":["Q1","Q2","Q3","Q4"],"series":[{"name":"Revenue","data":[12500,18400,16200,24700]}],"xAxis":{"label":"Quarter"},"yAxis":{"label":"Revenue (USD)","format":{"prefix":"$","decimals":0}},"source":"Quarterly report"}
```

## Agent tools and APIs

The existing stdio MCP server, `tokenstat mcp`, advertises:

| Tool | Arguments | Result |
| --- | --- | --- |
| `chart_schema` | `{}` | Versioned JSON schema |
| `chart_examples` | `{}` | One synthetic example of every chart family |
| `chart_validate` | `{"chart": SPEC}` | Validated chart and a ready-to-use Markdown block |
| `chart_create` | `{"chart": SPEC}` | Validated chart and a ready-to-use Markdown block |

Include the returned `content[0].text` or `structuredContent.markdown` verbatim
in the reply. The tool does not send a message, start a turn, publish data, or
change a project. It works without a running desktop host. Agents also receive
format instructions in their standing chat instructions, so a configured MCP
connection is optional. Older hosts carry the Markdown through normally.
Older clients show the chart as a code block and can be updated independently.

The CLI validates without opening the usage archive:

```sh
tokenstat chart --schema
tokenstat chart --examples
tokenstat chart chart.json                 # validated Markdown
cat chart.json | tokenstat chart --json -   # normalized JSON
```

The dependency-free JavaScript helper uses the same validator as the clients:

```js
const {chart, validate, kinds} = require('./sdk/index.cjs');
console.log(chart({version: 1, type: 'pie', title: 'Orders by channel',
  categories: ['Web', 'Store'], series: [{name: 'Orders', data: [120, 80]}]}));
```

The Python helper delegates validation to a tokenstat 1.8 or newer CLI:

```python
from tokenstat_charts import chart
print(chart({"version": 1, "type": "line", "title": "Daily orders",
             "categories": ["Mon", "Tue", "Wed"],
             "series": [{"name": "Orders", "data": [12, None, 18]}]}))
```

Place `sdk` on the Python import path. A test build can be selected with
`chart(spec, executable="path/to/tokenstat")`. Both helpers return Markdown
for the agent's reply. They do not communicate with a model or server.

## Data contract

See [schema.json](schema.json) and [examples.json](examples.json) for the complete
contract. Version one deliberately accepts data and presentation intent rather
than arbitrary ECharts options, HTML, scripts, callbacks, images or data URLs.

| Type | Data in each series | Categories |
| --- | --- | --- |
| `bar`, `line`, `area` | Numbers or `null` for missing observations | One label per observation |
| `pie`, `donut`, `funnel`, `treemap` | Nonnegative numbers, at least one positive | One label per observation, one series |
| `scatter` | `[x, y]` numeric tuples | Omit |
| `bubble` | `[x, y, size]`, size positive | Omit |
| `heatmap` | `[xIndex, yIndex, value]`, unique cells | Both `categories` and `yCategories`, one series |
| `radar` | Nonnegative numbers | Three to twelve labels |
| `boxplot` | `[minimum, Q1, median, Q3, maximum]` in increasing order | One label per distribution |

Optional fields are `subtitle`, `description`, `source`, `xAxis`, `yAxis`,
`stacked`, `horizontal`, and `showLabels`. Each axis has `label` and `format`.
The format has `prefix`, `suffix`, and `decimals` from zero through eight.
Formatting does not rescale data. A percentage value of 42 with suffix `%`
is shown as 42%. Category and series names must be unique and nonempty.

Use `stacked` for bars, lines or areas, and `horizontal` for bars. A flat treemap
compares category magnitudes. Scatter and bubble axes are numeric. Use category
labels for a dated line series. Missing observations are kept as gaps. A chart
must contain at least one numeric observation.

Limits are 256 KiB of normalized JSON, 16 series, 512 categories per axis, and
10,000 observations per chart. All numbers must be finite and within +/-1e15.
Aggregate a larger dataset before presenting it. Numeric strings are rejected.
Unknown fields and inconsistent point shapes are errors. Never invent values
or replace missing observations with zero. Explain the data source and units.

## Interaction and accessibility

Hover or tap a mark to inspect it. Click or tap selects its values, with Copy
selection available for follow-up questions. Focus the plot and use arrow keys
or Enter to inspect observations. Escape clears selection. Legends toggle
series or categories. Larger Cartesian charts have a zoom slider. Control plus
mouse wheel zooms where supported, while ordinary scrolling stays with the chat.
Reset restores the series and range. Expand gives the plot more vertical room.

Data opens a selectable, accessible table, paginated in groups of fifty rows.
All values, including missing observations and boxplot statistics, remain
available there. Color is supported by series names and the data table. Themes,
locale-aware number formatting, reduced motion and native screen readers are
supported. Chart state is local to the view and does not send agent messages.

Export creates PNG, SVG, CSV, or chart JSON through the native Save interface.
CSV and JSON contain the complete data, including points outside a zoomed view.
CSV text fields are protected against spreadsheet formula interpretation.
Image exports include title and source. Save cancellation preserves the chart.

## Runtime, packaging and tests

The shared runtime is copied as a folder into Apple app resources, Windows
`Assets/Charts`, and Android assets. No CDN or runtime download is used. Each
client blocks navigation away from the bundled page. A restrictive content
policy blocks network access, frames and plugins. The native bridge accepts
only bounded layout, clipboard and export messages from that page. Charts
never inherit a browsing profile or receive host command access.

Dependencies are pinned in `package-lock.json`. `build.mjs` builds a selective
engine, records its SHA-256, and bundles Apache ECharts, zrender and d3 notices.
The runtime also reuses the app's bundled Manrope typeface and its OFL notice.
The native package notice generators include those licenses as well.

```sh
npm ci --prefix apps/charts
npm --prefix apps/charts run build
npm --prefix apps/charts test
apps/charts/node_modules/.bin/playwright install chromium webkit
node apps/charts/tests/browser.mjs
python3 scripts/tests/check-chat-chart-fences.py
```

The browser suite renders every family in Chromium and WebKit at phone,
tablet and desktop widths in both themes. It checks keyboard inspection,
data tables, export output, error states and hostile labels. Rust and
JavaScript share acceptance and rejection fixtures. Native tests additionally
exercise the platform container and its lifecycle. Generated screenshots and
QA application bundles belong under ignored `target/`, never in the repository.
