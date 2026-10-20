// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import * as echarts from "echarts/core";
import {
    BarChart,
    LineChart,
    PieChart,
    ScatterChart,
    HeatmapChart,
    RadarChart,
    FunnelChart,
    TreemapChart,
    BoxplotChart,
} from "echarts/charts";
import {
    TitleComponent,
    GraphicComponent,
    GridComponent,
    LegendComponent,
    TooltipComponent,
    DataZoomComponent,
    VisualMapComponent,
    RadarComponent,
    AriaComponent,
} from "echarts/components";
import { SVGRenderer } from "echarts/renderers";
echarts.use([
    BarChart,
    LineChart,
    PieChart,
    ScatterChart,
    HeatmapChart,
    RadarChart,
    FunnelChart,
    TreemapChart,
    BoxplotChart,
    TitleComponent,
    GraphicComponent,
    GridComponent,
    LegendComponent,
    TooltipComponent,
    DataZoomComponent,
    VisualMapComponent,
    RadarComponent,
    AriaComponent,
    SVGRenderer,
]);
export { echarts };
