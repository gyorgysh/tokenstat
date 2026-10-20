// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! A portable, data-only chart contract. The renderer never receives executable options.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// Bounds keep a reply useful on phones as well as desktops.
pub const MAX_BYTES: usize = 256 * 1024;
/// The fence is deliberately specific so ordinary source remains ordinary source.
pub const FENCE: &str = "tokenstat-chart";
/// Chart families supported by every shipped renderer.
pub const KINDS: &[&str] = &[
    "bar", "line", "area", "pie", "donut", "scatter", "bubble", "heatmap", "radar", "funnel",
    "treemap", "boxplot",
];

/// Axis labels describe quantities and units rather than relying on surrounding prose.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Axis {
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub format: Format,
}

/// Formatting is declarative, with no JavaScript formatter callbacks.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Format {
    #[serde(default)]
    pub prefix: String,
    #[serde(default)]
    pub suffix: String,
    #[serde(default = "default_decimals", deserialize_with = "integer")]
    pub decimals: u8,
}

impl Default for Format {
    fn default() -> Self {
        Self {
            prefix: String::new(),
            suffix: String::new(),
            decimals: 2,
        }
    }
}

// JSON Schema integers include mathematical integers such as 1.0.
fn integer<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<u8, D::Error> {
    let value = Value::deserialize(deserializer)?;
    value
        .as_f64()
        .filter(|n| n.is_finite() && n.fract() == 0.0 && (0.0..=255.0).contains(n))
        .map(|n| n as u8)
        .ok_or_else(|| serde::de::Error::custom("Expected an integer between 0 and 255"))
}

fn default_decimals() -> u8 {
    2
}

/// A series preserves missing observations as null, rather than inventing zeroes.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Series {
    pub name: String,
    pub data: Vec<Value>,
}

/// Version one is deliberately smaller than a renderer's configuration language.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Chart {
    #[serde(deserialize_with = "integer")]
    pub version: u8,
    #[serde(rename = "type")]
    pub kind: String,
    pub title: String,
    #[serde(default)]
    pub subtitle: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub categories: Vec<String>,
    #[serde(default)]
    pub y_categories: Vec<String>,
    pub series: Vec<Series>,
    #[serde(default)]
    pub x_axis: Axis,
    #[serde(default)]
    pub y_axis: Axis,
    #[serde(default)]
    pub stacked: bool,
    #[serde(default)]
    pub horizontal: bool,
    #[serde(default)]
    pub show_labels: bool,
}

fn label(value: &str, max: usize, name: &str) -> Result<(), String> {
    if value.chars().count() > max
        || value
            .chars()
            .any(|c| c.is_control() && c != '\n' && c != '\t')
    {
        return Err(format!("{name} is too long or contains control characters"));
    }
    Ok(())
}

fn number(value: &Value) -> Option<f64> {
    value.as_f64().filter(|n| n.is_finite() && n.abs() <= 1e15)
}

impl Chart {
    /// Validate before storing, printing a fence or passing data to a client.
    pub fn parse(source: &str) -> Result<Self, String> {
        if source.len() > MAX_BYTES {
            return Err("A chart may contain at most 256 KiB of JSON".into());
        }
        let chart: Self =
            serde_json::from_str(source).map_err(|error| format!("Invalid chart JSON: {error}"))?;
        chart.validate()?;
        Ok(chart)
    }

    /// Reject misleading data shapes and bound work independently of serialized size.
    pub fn validate(&self) -> Result<(), String> {
        if self.version != 1 {
            return Err("Unsupported chart version. Use version 1".into());
        }
        if !KINDS.contains(&self.kind.as_str()) {
            return Err(format!("Unsupported chart type: {}", self.kind));
        }
        if self.title.trim().is_empty() {
            return Err("A chart needs a descriptive title".into());
        }
        for (value, max, name) in [
            (&self.title, 180, "title"),
            (&self.subtitle, 500, "subtitle"),
            (&self.description, 2000, "description"),
            (&self.source, 500, "source"),
        ] {
            label(value, max, name)?;
        }
        for axis in [&self.x_axis, &self.y_axis] {
            label(&axis.label, 120, "axis label")?;
            label(&axis.format.prefix, 24, "number prefix")?;
            label(&axis.format.suffix, 24, "number suffix")?;
            if axis.format.decimals > 8 {
                return Err("Number precision must be between 0 and 8".into());
            }
        }
        if self.categories.len() > 512 || self.y_categories.len() > 512 {
            return Err("An axis may have at most 512 categories".into());
        }
        for categories in [&self.categories, &self.y_categories] {
            let mut seen = std::collections::HashSet::new();
            for category in categories {
                label(category, 160, "category")?;
                if category.trim().is_empty() || !seen.insert(category) {
                    return Err("Category names must be nonempty and unique".into());
                }
            }
        }
        if self.series.is_empty() || self.series.len() > 16 {
            return Err("A chart needs between 1 and 16 series".into());
        }
        let single = ["pie", "donut", "funnel", "treemap", "heatmap"].contains(&self.kind.as_str());
        if single && self.series.len() != 1 {
            return Err(format!("{} charts need exactly one series", self.kind));
        }
        if self.stacked && !["bar", "line", "area"].contains(&self.kind.as_str()) {
            return Err("Stacking is supported for bar, line and area charts".into());
        }
        if self.horizontal && self.kind != "bar" {
            return Err("Horizontal orientation is supported for bar charts".into());
        }
        if !self.y_categories.is_empty() && self.kind != "heatmap" {
            return Err("yCategories belongs to heatmaps".into());
        }
        let xy = ["scatter", "bubble"].contains(&self.kind.as_str());
        if xy && !self.categories.is_empty() {
            return Err(
                "Scatter and bubble charts use numeric coordinates, without categories".into(),
            );
        }
        if !xy && self.categories.is_empty() {
            return Err("This chart needs category labels".into());
        }
        if self.kind == "radar" && !(3..=12).contains(&self.categories.len()) {
            return Err("Radar charts need between 3 and 12 categories".into());
        }
        if self.kind == "heatmap" && self.y_categories.is_empty() {
            return Err("Heatmaps need yCategories".into());
        }
        let mut count = 0;
        let mut observations = 0;
        let mut names = std::collections::HashSet::new();
        for series in &self.series {
            label(&series.name, 160, "series name")?;
            if series.name.trim().is_empty() || !names.insert(&series.name) {
                return Err("Series names must be nonempty and unique".into());
            }
            count += series.data.len();
            if series.data.is_empty() || count > 10_000 {
                return Err("A chart needs data and may have at most 10000 points".into());
            }
            if !xy && self.kind != "heatmap" && series.data.len() != self.categories.len() {
                return Err("Each series must have one value for every category. Use null for missing observations".into());
            }
            let mut positive = false;
            let mut cells = std::collections::HashSet::new();
            for point in &series.data {
                if xy || ["heatmap", "boxplot"].contains(&self.kind.as_str()) {
                    observations += 1;
                    let width = match self.kind.as_str() {
                        "scatter" => 2,
                        "boxplot" => 5,
                        _ => 3,
                    };
                    let values =
                        point
                            .as_array()
                            .filter(|v| v.len() == width)
                            .ok_or_else(|| {
                                format!("{} points must be arrays of {width} numbers", self.kind)
                            })?;
                    let values: Vec<f64> = values
                        .iter()
                        .map(|v| {
                            number(v).ok_or_else(|| {
                                "Data must contain finite numbers between -1e15 and 1e15"
                                    .to_string()
                            })
                        })
                        .collect::<Result<_, _>>()?;
                    if self.kind == "bubble" && values[2] <= 0.0 {
                        return Err("Bubble sizes must be positive".into());
                    }
                    if self.kind == "boxplot" && values.windows(2).any(|v| v[0] > v[1]) {
                        return Err(
                            "Boxplot values must be ordered: minimum, Q1, median, Q3, maximum"
                                .into(),
                        );
                    }
                    if self.kind == "heatmap" {
                        if values[0].fract() != 0.0
                            || values[1].fract() != 0.0
                            || values[0] < 0.0
                            || values[1] < 0.0
                            || values[0] >= self.categories.len() as f64
                            || values[1] >= self.y_categories.len() as f64
                        {
                            return Err(
                                "Heatmap coordinates must index categories and yCategories".into(),
                            );
                        }
                        if !cells.insert((values[0] as usize, values[1] as usize)) {
                            return Err("Heatmap cells must have unique coordinates".into());
                        }
                    }
                } else if !point.is_null() {
                    observations += 1;
                    let value = number(point).ok_or_else(|| {
                        "Values must be finite numbers between -1e15 and 1e15, or null".to_string()
                    })?;
                    if ["pie", "donut", "funnel", "treemap", "radar"].contains(&self.kind.as_str())
                        && value < 0.0
                    {
                        return Err("This chart type cannot represent negative values".into());
                    }
                    positive |= value > 0.0;
                } else if ["pie", "donut", "funnel", "treemap", "radar"]
                    .contains(&self.kind.as_str())
                {
                    return Err("This chart type needs a number for every category".into());
                }
            }
            if ["pie", "donut", "funnel", "treemap"].contains(&self.kind.as_str()) && !positive {
                return Err("This chart needs at least one positive value".into());
            }
        }
        if observations == 0 {
            return Err("A chart needs at least one numeric observation".into());
        }
        if serde_json::to_vec(self).map_err(|e| e.to_string())?.len() > MAX_BYTES {
            return Err("The normalized chart exceeds 256 KiB".into());
        }
        Ok(())
    }

    /// A normal transcript remains the durable transport, including on older hosts.
    pub fn fence(&self) -> Result<String, String> {
        self.validate()?;
        let data = serde_json::to_string(self).map_err(|e| e.to_string())?;
        if data.len() > MAX_BYTES {
            return Err("The normalized chart exceeds 256 KiB".into());
        }
        Ok(format!("```{FENCE}\n{data}\n```"))
    }
}

/// Tool discovery exposes a portable JSON schema rather than renderer internals.
pub fn schema() -> Value {
    serde_json::from_str(include_str!("../../../apps/charts/schema.json"))
        .unwrap_or_else(|_| json!({}))
}

/// The same examples drive documentation, agent discovery and client regression checks.
pub fn examples() -> Value {
    serde_json::from_str(include_str!("../../../apps/charts/examples.json"))
        .unwrap_or_else(|_| json!([]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_example_is_valid_and_round_trips() {
        let examples = examples();
        for example in examples.as_array().expect("examples") {
            let chart = Chart::parse(&example.to_string()).expect("valid example");
            assert!(
                chart
                    .fence()
                    .expect("fence")
                    .starts_with("```tokenstat-chart\n")
            );
        }
        assert_eq!(examples.as_array().expect("examples").len(), KINDS.len());
    }

    #[test]
    fn schema_and_numeric_defaults_match_the_client_contract() {
        let source = examples()[0]
            .to_string()
            .replace("\"version\":1", "\"version\":1.0");
        let chart = Chart::parse(&source).expect("mathematical integer");
        assert_eq!(chart.x_axis.format.decimals, 2);
        assert_eq!(schema()["properties"]["type"]["enum"], json!(KINDS));
    }

    #[test]
    fn rejects_invalid_contract_cases() {
        let cases: Value = serde_json::from_str(include_str!("../../../apps/charts/invalid.json"))
            .expect("fixtures");
        for case in cases.as_array().expect("array") {
            assert!(
                Chart::parse(&case["spec"].to_string()).is_err(),
                "{}",
                case["name"]
            );
        }
    }

    #[test]
    fn enforces_serialized_and_point_limits() {
        assert!(Chart::parse(&" ".repeat(MAX_BYTES + 1)).is_err());
        let mut chart = Chart::parse(&examples()[5].to_string()).expect("scatter");
        chart.series[0].data = vec![json!([0, 1]); 10001];
        assert!(chart.validate().is_err());
    }
}
