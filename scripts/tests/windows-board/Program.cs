// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;
static JsonNode Card(string id, string column, long order) => new JsonObject { ["id"] = id, ["column"] = column, ["order"] = order };
static void Check(bool value, string message) { if (!value) throw new Exception(message); }
var cards = new[] { Card("a", "backlog", 0), Card("hidden", "backlog", 1), Card("b", "backlog", 2), Card("c", "doing", 0) };
Check(TaskBoardOrder.InsertionIndex(cards, "c", "backlog", "b") == 2, "Hidden tasks count in the host column index.");
Check(TaskBoardOrder.InsertionIndex(cards, "a", "backlog", "b", true) == 2, "Moving down excludes the dragged card.");
Check(TaskBoardOrder.InsertionIndex(cards, "b", "backlog", "a") == 0, "Moving up lands before the anchor.");
Check(TaskBoardOrder.InsertionIndex(cards, "a", "backlog") == 2, "Column whitespace appends the card.");
Check(TaskBoardOrder.InsertionIndex(cards, "missing", "backlog") is null, "External text is not a task.");
Check(TaskBoardOrder.InsertionIndex(cards, "a", "backlog", "missing") is null, "A stale anchor must not move the task.");
Console.WriteLine("Board insertion tests passed.");

var creationDraft = new TaskCreationDraft();
creationDraft.Edited();
var submittedDraft = creationDraft.Revision;
if (!creationDraft.Accepts(submittedDraft)) throw new Exception("An unchanged task draft was not accepted");
creationDraft.Edited();
creationDraft.Edited(); // Replacing a draft with identical text still creates a newer edit.
if (creationDraft.Accepts(submittedDraft)) throw new Exception("A delayed creation receipt cleared a newer task draft");
Console.WriteLine("Task creation: delayed receipts preserve newer stage drafts");
