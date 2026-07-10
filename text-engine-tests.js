#!/usr/bin/env node

const fs = require("fs");
const assert = require("assert");
const childProcess = require("child_process");

const plistPath = `${__dirname}/Resources/com.schlub51.textmenuplus.styles.plist`;
const styles = JSON.parse(childProcess.execFileSync("plutil", ["-convert", "json", "-o", "-", plistPath], { encoding: "utf8" }));
const byName = new Map(styles.map((style) => [style.name, style]));

const reverseInfo = new Map();
function shouldReplacePlain(existingPlain, newPlain) {
  if (!existingPlain || !newPlain) return !existingPlain && !!newPlain;
  const existingLower = existingPlain === existingPlain.toLowerCase();
  const newLower = newPlain === newPlain.toLowerCase();
  if (newLower && !existingLower) return true;
  if (newLower === existingLower && newPlain < existingPlain) return true;
  return false;
}

for (const style of styles) {
  if (!style.map) continue;
  for (const [plain, styled] of Object.entries(style.map)) {
    if (!styled || styled === plain) continue;
    const existing = reverseInfo.get(styled);
    if (!existing || shouldReplacePlain(existing.plain, plain)) {
      reverseInfo.set(styled, { plain, name: style.name });
    }
  }
}

const combineMarks = [...new Set(styles.flatMap((style) => [...(style.combine || "")]))];

function graphemes(text) {
  return [...text];
}

function stripCombines(text) {
  let result = text;
  for (const mark of combineMarks) result = result.split(mark).join("");
  return result;
}

function plain(text) {
  return graphemes(stripCombines(text)).map((ch) => reverseInfo.get(ch)?.plain || ch).join("");
}

function styleName(text) {
  const counts = new Map();
  let styledCount = 0;
  let letterCount = 0;
  for (const ch of graphemes(stripCombines(text))) {
    if (/\p{L}/u.test(ch)) letterCount += 1;
    const name = reverseInfo.get(ch)?.name;
    if (!name) continue;
    styledCount += 1;
    counts.set(name, (counts.get(name) || 0) + 1);
  }
  if (styledCount < 2) return null;
  if (letterCount > 0 && styledCount * 2 < letterCount) return null;
  const [dominantName, dominantCount] = [...counts.entries()].sort((a, b) => b[1] - a[1])[0] || [];
  return dominantCount * 2 >= styledCount ? dominantName : null;
}

function combineName(text) {
  return styles.find((style) => style.combine && text.includes(style.combine))?.name || null;
}

function applyStyle(text, name) {
  const map = byName.get(name)?.map;
  if (!map) return text;
  return graphemes(text).map((ch) => map[ch] || ch).join("");
}

function applyCombine(text, name) {
  const combine = byName.get(name)?.combine;
  if (!combine) return text;
  return graphemes(text).map((ch) => /\s/.test(ch) ? ch : ch + combine).join("");
}

function render(base, style, combine) {
  let result = style ? applyStyle(base, style) : base;
  if (combine) result = applyCombine(result, combine);
  return result;
}

function transform(text, fn) {
  return render(fn(plain(text)), styleName(text), combineName(text));
}

function command(text, name) {
  if (name === "plain") return plain(text);
  if (name === "upper") return transform(text, (s) => s.toUpperCase());
  if (name === "lower") return transform(text, (s) => s.toLowerCase());
  if (name === "caps") return transform(text, (s) => s.replace(/\b\p{L}/gu, (c) => c.toUpperCase()));
  if (byName.get(name)?.map) return render(plain(text), name, combineName(text));
  if (byName.get(name)?.combine) return render(plain(text), styleName(text), name);
  throw new Error(`unknown command ${name}`);
}

function runSequence(input, commands) {
  return commands.reduce((text, cmd) => command(text, cmd), input);
}

assert.strictEqual(runSequence("snowboard", ["bold", "upper", "plain"]), "SNOWBOARD");
assert.strictEqual(runSequence("snowboard", ["bold", "upper", "plain", "lower"]), "snowboard");
assert.strictEqual(runSequence("snowboard", ["smallCaps", "plain", "lower"]), "snowboard");
assert.strictEqual(runSequence("snowboard", ["russian", "plain", "lower"]), "snowboard");
assert.strictEqual(runSequence("snowboard", ["russian", "plain"]), "snowboard");
assert.strictEqual(runSequence("snowboard", ["greek", "plain"]), "snowboard");
assert.strictEqual(runSequence("snowboard", ["bold", "tears", "lower", "plain"]), "snowboard");
assert.strictEqual(styleName("SNOWBOARD"), null);
assert.strictEqual(styleName("snowboard"), null);

console.log("text engine tests passed");
