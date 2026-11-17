// Storage checks for survey-timing.js, run against a fake Qualtrics engine:
//
//   node tools/survey-timing.test.js
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

function run(opts) {
  const ed = {};
  let onReady = [];
  let onSubmit = [];
  const listeners = {};
  const doc = {
    currentScript: null,
    hidden: false,
    addEventListener: (t, f) => ((listeners[t] = listeners[t] || []).push(f)),
  };
  const win = {
    console: { log() {}, warn: console.warn, error: console.error },
    SURVEY_TIMING_CONFIG: opts.config,
    addEventListener() {},
    Qualtrics: {
      SurveyEngine: {
        addOnReady: (f) => onReady.push(f),
        addOnPageSubmit: (f) => onSubmit.push(f),
        // setJSEmbeddedData adds the __js_ prefix itself; mirror that.
        setJSEmbeddedData: (k, v) => {
          const bytes = Buffer.byteLength(v);
          if (bytes > 20000) throw new Error(`${k} is ${bytes} bytes`);
          ed["__js_" + k] = v;
        },
        getJSEmbeddedData: (k) => ed["__js_" + k],
      },
    },
  };
  win.window = win;
  const ctx = vm.createContext({
    window: win,
    document: doc,
    Qualtrics: win.Qualtrics,
    TextEncoder,
    WeakMap,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    console,
    Date,
    JSON,
    Math,
    unescape,
    encodeURIComponent,
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../inst/js/survey-timing.js"), "utf8"), ctx);

  const change = (qid) =>
    listeners.change.forEach((f) =>
      f({ target: { type: "radio", name: qid, tagName: "INPUT" } }),
    );

  function page(nEvents, resubmit) {
    const ready = onReady;
    onReady = [];
    ready.forEach((f) => f());
    for (let j = 0; j < nEvents; j++) change("QID" + (100 + j));
    const sub = onSubmit;
    onSubmit = [];
    sub.forEach((f) => f());
    if (resubmit) sub.forEach((f) => f());
    // Qualtrics registers addOnReady once; the script re-arms per page.
    win.SurveyTiming.rearm();
  }
  return { ed, page, win };
}

const fields = (ed) =>
  Object.keys(ed)
    .sort()
    .map((k) => [k, Buffer.byteLength(ed[k]), JSON.parse(ed[k]).p.length]);

// 1. A long survey: 150 pages, 8 events each, default config.
let r = run({});
for (let p = 0; p < 150; p++) r.page(8, p % 10 === 0);
let f = fields(r.ed);
console.log("150 pages x 8 events:", f);
let all = r.win.SurveyTiming.state();
assert.strictEqual(all.length, 150, "every page stored once");
assert.strictEqual(
  JSON.stringify(all.map((p) => p.i)),
  JSON.stringify([...Array(150).keys()]),
  "indexes contiguous, no duplicates from resubmits",
);
f.forEach(([, b]) => assert(b <= 19500));
console.log("bytes per page ~", Math.round(f.reduce((a, x) => a + x[1], 0) / 150));
console.log("sample:", r.ed.__js_timing.slice(0, 160));

// 2. Overflow: tiny budget, two fields, so the last field has to trim.
r = run({ config: { maxBytes: 1500, maxFields: 2 } });
for (let p = 0; p < 40; p++) r.page(8);
f = fields(r.ed);
console.log("overflow:", f);
f.forEach(([, b]) => assert(b <= 1500));
all = r.win.SurveyTiming.state();
console.log(
  "trimmed pages:",
  all.filter((p) => p.d).map((p) => `${p.i}(-${p.d})`).join(" "),
);

// 3. One enormous page (2,000 events) must be trimmed, never block a submit.
r = run({});
r.page(3);
r.page(2000);
r.page(3);
f = fields(r.ed);
console.log("huge page:", f);
all = r.win.SurveyTiming.state();
console.log(all.map((p) => `${p.i}:${p.e.length}${p.d ? "-" + p.d : ""}`).join(" "));
assert.strictEqual(all.length, 3, "page after the huge one still stored");

// 4. maxBytes above Qualtrics' ceiling gets clamped.
r = run({ config: { maxBytes: 50000, maxFields: 1 } });
assert.strictEqual(r.win.SurveyTiming.config.maxBytes, 20000);
for (let p = 0; p < 400; p++) r.page(8);
console.log("clamped:", fields(r.ed));
console.log("all checks passed");
