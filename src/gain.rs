use crate::display_helpers::{format_duration, print_period_table};
use crate::tracking::{DayStats, MonthStats, Tracker, WeekStats};
use crate::utils::format_tokens;
use anyhow::{Context, Result};
use serde::Serialize;

pub fn run(
    graph: bool,
    history: bool,
    quota: bool,
    tier: &str,
    daily: bool,
    weekly: bool,
    monthly: bool,
    all: bool,
    format: &str,
    _verbose: u8,
) -> Result<()> {
    let tracker = Tracker::new().context("Failed to initialize tracking database")?;

    // Handle export formats
    match format {
        "json" => return export_json(&tracker, daily, weekly, monthly, all),
        "csv" => return export_csv(&tracker, daily, weekly, monthly, all),
        _ => {} // Continue with text format
    }

    let summary = tracker
        .get_summary()
        .context("Failed to load token savings summary from database")?;

    if summary.total_commands == 0 {
        println!("No tracking data yet.");
        println!("Run some rtk commands to start tracking savings.");
        return Ok(());
    }

    // Default view (summary)
    if !daily && !weekly && !monthly && !all {
        println!("📊 RTK Token Savings");
        println!("════════════════════════════════════════");
        println!();

        println!("Total commands:    {}", summary.total_commands);
        println!("Input tokens:      {}", format_tokens(summary.total_input));
        println!("Output tokens:     {}", format_tokens(summary.total_output));
        println!(
            "Tokens saved:      {} ({:.1}%)",
            format_tokens(summary.total_saved),
            summary.avg_savings_pct
        );
        println!(
            "Total exec time:   {} (avg {})",
            format_duration(summary.total_time_ms),
            format_duration(summary.avg_time_ms)
        );
        println!();

        if !summary.by_command.is_empty() {
            let by_command = normalize_by_command(summary.by_command);
            println!("By Command:");
            println!("────────────────────────────────────────");
            println!(
                "{:<20} {:>6} {:>10} {:>8} {:>8}",
                "Command", "Count", "Saved", "Avg%", "Time"
            );
            for (cmd, count, saved, pct, avg_time) in &by_command {
                let cmd_short = if cmd.len() > 18 {
                    format!("{}...", &cmd[..15])
                } else {
                    cmd.clone()
                };
                println!(
                    "{:<20} {:>6} {:>10} {:>7.1}% {:>8}",
                    cmd_short,
                    count,
                    format_tokens(*saved),
                    pct,
                    format_duration(*avg_time)
                );
            }
            println!();
        }

        if graph && !summary.by_day.is_empty() {
            println!("Daily Savings (last 30 days):");
            println!("────────────────────────────────────────");
            print_ascii_graph(&summary.by_day);
            println!();
        }

        if history {
            let recent = tracker.get_recent(10)?;
            if !recent.is_empty() {
                println!("Recent Commands:");
                println!("────────────────────────────────────────");
                for rec in recent {
                    let time = rec.timestamp.format("%m-%d %H:%M");
                    let cmd_name = normalize_cmd_name(&rec.rtk_cmd);
                    let cmd_short = if cmd_name.len() > 25 {
                        format!("{}...", &cmd_name[..22])
                    } else {
                        cmd_name
                    };
                    println!(
                        "{} {:<25} -{:.0}% ({})",
                        time,
                        cmd_short,
                        rec.savings_pct,
                        format_tokens(rec.saved_tokens)
                    );
                }
                println!();
            }
        }

        if quota {
            const ESTIMATED_PRO_MONTHLY: usize = 6_000_000;

            let (quota_tokens, tier_name) = match tier {
                "pro" => (ESTIMATED_PRO_MONTHLY, "Pro ($20/mo)"),
                "5x" => (ESTIMATED_PRO_MONTHLY * 5, "Max 5x ($100/mo)"),
                "20x" => (ESTIMATED_PRO_MONTHLY * 20, "Max 20x ($200/mo)"),
                _ => (ESTIMATED_PRO_MONTHLY, "Pro ($20/mo)"),
            };

            let quota_pct = (summary.total_saved as f64 / quota_tokens as f64) * 100.0;

            println!("Monthly Quota Analysis:");
            println!("────────────────────────────────────────");
            println!("Subscription tier:        {}", tier_name);
            println!("Estimated monthly quota:  {}", format_tokens(quota_tokens));
            println!(
                "Tokens saved (lifetime):  {}",
                format_tokens(summary.total_saved)
            );
            println!("Quota preserved:          {:.1}%", quota_pct);
            println!();
            println!("Note: Heuristic estimate based on ~44K tokens/5h (Pro baseline)");
            println!("      Actual limits use rolling 5-hour windows, not monthly caps.");
        }

        return Ok(());
    }

    // Time breakdown views
    if all || daily {
        print_daily_full(&tracker)?;
    }

    if all || weekly {
        print_weekly(&tracker)?;
    }

    if all || monthly {
        print_monthly(&tracker)?;
    }

    Ok(())
}

fn print_ascii_graph(data: &[(String, usize)]) {
    if data.is_empty() {
        return;
    }

    let max_val = data.iter().map(|(_, v)| *v).max().unwrap_or(1);
    let width = 40;

    for (date, value) in data {
        let date_short = if date.len() >= 10 { &date[5..10] } else { date };

        let bar_len = if max_val > 0 {
            ((*value as f64 / max_val as f64) * width as f64) as usize
        } else {
            0
        };

        let bar: String = "█".repeat(bar_len);
        let spaces: String = " ".repeat(width - bar_len);

        println!(
            "{} │{}{} {}",
            date_short,
            bar,
            spaces,
            format_tokens(*value)
        );
    }
}

fn print_daily_full(tracker: &Tracker) -> Result<()> {
    let days = tracker.get_all_days()?;
    print_period_table(&days);
    Ok(())
}

fn print_weekly(tracker: &Tracker) -> Result<()> {
    let weeks = tracker.get_by_week()?;
    print_period_table(&weeks);
    Ok(())
}

fn print_monthly(tracker: &Tracker) -> Result<()> {
    let months = tracker.get_by_month()?;
    print_period_table(&months);
    Ok(())
}

#[derive(Serialize)]
struct ExportData {
    summary: ExportSummary,
    #[serde(skip_serializing_if = "Option::is_none")]
    daily: Option<Vec<DayStats>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    weekly: Option<Vec<WeekStats>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    monthly: Option<Vec<MonthStats>>,
}

#[derive(Serialize)]
struct ExportSummary {
    total_commands: usize,
    total_input: usize,
    total_output: usize,
    total_saved: usize,
    avg_savings_pct: f64,
    total_time_ms: u64,
    avg_time_ms: u64,
}

fn export_json(
    tracker: &Tracker,
    daily: bool,
    weekly: bool,
    monthly: bool,
    all: bool,
) -> Result<()> {
    let summary = tracker
        .get_summary()
        .context("Failed to load token savings summary from database")?;

    let export = ExportData {
        summary: ExportSummary {
            total_commands: summary.total_commands,
            total_input: summary.total_input,
            total_output: summary.total_output,
            total_saved: summary.total_saved,
            avg_savings_pct: summary.avg_savings_pct,
            total_time_ms: summary.total_time_ms,
            avg_time_ms: summary.avg_time_ms,
        },
        daily: if all || daily {
            Some(tracker.get_all_days()?)
        } else {
            None
        },
        weekly: if all || weekly {
            Some(tracker.get_by_week()?)
        } else {
            None
        },
        monthly: if all || monthly {
            Some(tracker.get_by_month()?)
        } else {
            None
        },
    };

    let json = serde_json::to_string_pretty(&export)?;
    println!("{}", json);

    Ok(())
}

/// Normalize stored rtk_cmd names to canonical user-facing command names.
///
/// Historical entries may use internal names that don't match what users type.
/// The hook now preserves original command names (cat, rg, eslint), so gain
/// output should reflect those names.
fn normalize_cmd_name(cmd: &str) -> String {
    // Exact prefix replacements for renamed commands
    if cmd == "rtk run-err" {
        return "rtk err".to_string();
    }
    if cmd == "rtk run-test" {
        return "rtk test".to_string();
    }
    // "rtk read" → "rtk cat" (preserving any suffix like " -")
    if cmd == "rtk read" || cmd.starts_with("rtk read ") {
        return cmd.replacen("rtk read", "rtk cat", 1);
    }
    cmd.to_string()
}

/// Re-aggregate by_command entries after normalization.
///
/// Multiple stored names may map to the same canonical name (e.g. "rtk read"
/// and "rtk cat" both map to "rtk cat"). This merges their stats using
/// weighted averages.
fn normalize_by_command(
    entries: Vec<(String, usize, usize, f64, u64)>,
) -> Vec<(String, usize, usize, f64, u64)> {
    use std::collections::HashMap;

    // Preserve insertion order via a separate vec of keys
    let mut order: Vec<String> = Vec::new();
    // Accumulate: (total_count, total_saved, weighted_pct_sum, weighted_time_sum)
    let mut merged: HashMap<String, (usize, usize, f64, f64)> = HashMap::new();

    for (cmd, count, saved, pct, avg_time) in entries {
        let canonical = normalize_cmd_name(&cmd);
        let entry = merged.entry(canonical.clone()).or_insert_with(|| {
            order.push(canonical);
            (0, 0, 0.0, 0.0)
        });
        entry.0 += count;
        entry.1 += saved;
        entry.2 += pct * count as f64;
        entry.3 += avg_time as f64 * count as f64;
    }

    order
        .into_iter()
        .map(|name| {
            let (count, saved, wpct, wtime) = merged.remove(&name).unwrap();
            let avg_pct = if count > 0 { wpct / count as f64 } else { 0.0 };
            let avg_time = if count > 0 {
                (wtime / count as f64) as u64
            } else {
                0
            };
            (name, count, saved, avg_pct, avg_time)
        })
        .collect()
}

fn export_csv(
    tracker: &Tracker,
    daily: bool,
    weekly: bool,
    monthly: bool,
    all: bool,
) -> Result<()> {
    if all || daily {
        let days = tracker.get_all_days()?;
        println!("# Daily Data");
        println!("date,commands,input_tokens,output_tokens,saved_tokens,savings_pct,total_time_ms,avg_time_ms");
        for day in days {
            println!(
                "{},{},{},{},{},{:.2},{},{}",
                day.date,
                day.commands,
                day.input_tokens,
                day.output_tokens,
                day.saved_tokens,
                day.savings_pct,
                day.total_time_ms,
                day.avg_time_ms
            );
        }
        println!();
    }

    if all || weekly {
        let weeks = tracker.get_by_week()?;
        println!("# Weekly Data");
        println!(
            "week_start,week_end,commands,input_tokens,output_tokens,saved_tokens,savings_pct,total_time_ms,avg_time_ms"
        );
        for week in weeks {
            println!(
                "{},{},{},{},{},{},{:.2},{},{}",
                week.week_start,
                week.week_end,
                week.commands,
                week.input_tokens,
                week.output_tokens,
                week.saved_tokens,
                week.savings_pct,
                week.total_time_ms,
                week.avg_time_ms
            );
        }
        println!();
    }

    if all || monthly {
        let months = tracker.get_by_month()?;
        println!("# Monthly Data");
        println!("month,commands,input_tokens,output_tokens,saved_tokens,savings_pct,total_time_ms,avg_time_ms");
        for month in months {
            println!(
                "{},{},{},{},{},{:.2},{},{}",
                month.month,
                month.commands,
                month.input_tokens,
                month.output_tokens,
                month.saved_tokens,
                month.savings_pct,
                month.total_time_ms,
                month.avg_time_ms
            );
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_cmd_run_err() {
        assert_eq!(normalize_cmd_name("rtk run-err"), "rtk err");
    }

    #[test]
    fn test_normalize_cmd_run_test() {
        assert_eq!(normalize_cmd_name("rtk run-test"), "rtk test");
    }

    #[test]
    fn test_normalize_cmd_read_to_cat() {
        assert_eq!(normalize_cmd_name("rtk read"), "rtk cat");
    }

    #[test]
    fn test_normalize_cmd_read_stdin_to_cat() {
        assert_eq!(normalize_cmd_name("rtk read -"), "rtk cat -");
    }

    #[test]
    fn test_normalize_cmd_passthrough() {
        // Commands that are already correct should pass through unchanged
        assert_eq!(normalize_cmd_name("rtk git status"), "rtk git status");
        assert_eq!(normalize_cmd_name("rtk cargo test"), "rtk cargo test");
        assert_eq!(normalize_cmd_name("rtk cat"), "rtk cat");
        assert_eq!(normalize_cmd_name("rtk ls"), "rtk ls");
        assert_eq!(normalize_cmd_name("rtk eslint ."), "rtk eslint .");
        assert_eq!(normalize_cmd_name("rtk grep"), "rtk grep");
    }

    #[test]
    fn test_normalize_by_command_merges_duplicates() {
        let entries = vec![
            ("rtk run-err".to_string(), 10, 500, 80.0, 100),
            ("rtk err".to_string(), 5, 300, 75.0, 50),
        ];
        let result = normalize_by_command(entries);
        // Should merge into single "rtk err" entry
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].0, "rtk err");
        assert_eq!(result[0].1, 15); // count: 10 + 5
        assert_eq!(result[0].2, 800); // saved: 500 + 300
                                      // weighted avg pct: (80*10 + 75*5) / 15 = 1175/15 ≈ 78.33
        assert!((result[0].3 - 78.33).abs() < 0.1);
        // weighted avg time: (100*10 + 50*5) / 15 = 1250/15 ≈ 83
        assert_eq!(result[0].4, 83);
    }

    #[test]
    fn test_normalize_by_command_preserves_order() {
        let entries = vec![
            ("rtk git status".to_string(), 20, 1000, 70.0, 50),
            ("rtk run-err".to_string(), 10, 500, 80.0, 100),
            ("rtk ls".to_string(), 5, 200, 60.0, 30),
        ];
        let result = normalize_by_command(entries);
        assert_eq!(result.len(), 3);
        // Order preserved (sorted by saved desc from SQL)
        assert_eq!(result[0].0, "rtk git status");
        assert_eq!(result[1].0, "rtk err"); // normalized
        assert_eq!(result[2].0, "rtk ls");
    }
}
