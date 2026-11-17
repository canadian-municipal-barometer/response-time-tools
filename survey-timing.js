/*!
 * survey-timing.js -- per-question response timing logger for Qualtrics.
 *
 * Records a client-side event log (page loads, answers, focus/visibility
 * changes, submits) into a Qualtrics embedded data field, for parsing with the
 * surveytiming R package.
 *
 * Repo: https://github.com/canadian-municipal-barometer/response-time-tools
 *
 * Usage -- Look & Feel -> Header -> edit -> Source (<>), then paste:
 *
 *   <script src="https://canadian-municipal-barometer.github.io/response-time-tools/survey-timing.js"></script>
 *
 * Qualtrics rejects a page submit outright when any one embedded data value is
 * over 20,000 bytes, so the log is spread across numbered fields: `timing`,
 * then `timing_2`, `timing_3`, ... up to `data-max-fields`. Every one of them
 * must exist in the survey flow (as __js_timing, __js_timing_2, ...) before it
 * can be written to. Override the defaults with attributes on the script tag:
 *
 *   <script
 *     src="https://canadian-municipal-barometer.github.io/response-time-tools/survey-timing.js"
 *     data-field="timing"
 *     data-max-fields="3"
 *     data-debounce="500"
 *     data-debug="false"
 *   ></script>
 */
(function (global) {
  "use strict";

  var VERSION = "2.0.0";

  // Qualtrics' per-value ceiling, in UTF-8 bytes. A submit carrying one byte
  // more is refused with "body.ed.<field> exceeds maximum byte size of 20000",
  // and the respondent cannot leave the page.
  var QUALTRICS_MAX_BYTES = 20000;

  // ---- CONFIG ----
  var config = {
    // Embedded data field the event log is written to. Overflow goes to
    // `<field>_2`, `<field>_3`, ...
    field: "timing",
    // How many fields the log may spread across. Once all are full, further
    // pages are stored with their events trimmed rather than not at all.
    maxFields: 3,
    // Bytes a field may hold before the log moves on to the next one. Kept
    // under QUALTRICS_MAX_BYTES so a miscount can never block a submit.
    maxBytes: 19500,
    // How long a text input must be idle before the typing burst is logged
    // as a single "input" event. 300-800ms is typical.
    inputDebounceMs: 500,
    // Mirror every logged event to the console (survey testing only).
    debug: false,
    // How long to wait for the Qualtrics survey engine to appear before
    // giving up. The engine is normally ready well inside this window; the
    // wait exists because an external script's execution order relative to
    // the Qualtrics bundle isn't guaranteed the way an inline header script's
    // is.
    engineTimeoutMs: 20000,
  };

  // Config precedence: script-tag data-* attributes, then a
  // window.SURVEY_TIMING_CONFIG object set before the script tag, then the
  // defaults above.
  function readConfig() {
    var preset = global.SURVEY_TIMING_CONFIG;
    if (preset && typeof preset === "object") {
      if (preset.field) config.field = String(preset.field);
      if (preset.inputDebounceMs != null) {
        config.inputDebounceMs = Number(preset.inputDebounceMs);
      }
      if (preset.debug != null) config.debug = Boolean(preset.debug);
      if (preset.maxFields != null) config.maxFields = Number(preset.maxFields);
      if (preset.maxBytes != null) config.maxBytes = Number(preset.maxBytes);
    }

    // document.currentScript is the tag being executed; it is null when the
    // file is inlined or eval'd, in which case the defaults stand.
    var tag = document.currentScript;
    if (tag && tag.getAttribute) {
      var field = tag.getAttribute("data-field");
      if (field) config.field = field;

      var debounce = parseInt(tag.getAttribute("data-debounce"), 10);
      if (!isNaN(debounce)) config.inputDebounceMs = debounce;

      var maxFields = parseInt(tag.getAttribute("data-max-fields"), 10);
      if (!isNaN(maxFields)) config.maxFields = maxFields;

      if (tag.getAttribute("data-debug") === "true") config.debug = true;
    }

    // Whatever was asked for, never let a value reach Qualtrics' ceiling.
    if (!(config.maxFields >= 1)) config.maxFields = 1;
    if (!(config.maxBytes > 0) || config.maxBytes > QUALTRICS_MAX_BYTES) {
      config.maxBytes = QUALTRICS_MAX_BYTES;
    }
  }

  function log() {
    if (!config.debug || !global.console) return;
    console.log.apply(console, ["[survey-timing]"].concat([].slice.call(arguments)));
  }

  // ---- STATE ----
  // `currentPage` is the page whose events are being collected right now. It
  // is swapped in by startPage() on every Qualtrics "ready", so the document
  // listeners below (installed once) always write to the page actually on
  // screen.
  //
  // Storage format (v2), one JSON document per field:
  //
  //   {"v":2,"p":[{"i":0,"t":1761590000000,"s":15234,"e":[[812,"c","QID5","radio"]]}]}
  //
  //   i  page index, counted across all fields
  //   t  page load time, epoch milliseconds
  //   s  submit time, milliseconds after load
  //   e  events: [ms after load, type code, question id, input type], with
  //      trailing empty entries dropped
  //   d  events trimmed off the end of this page to make it fit (rare)
  //
  // v1 stored ISO timestamps and long keys on every event, about three times
  // the size, which pushed a long survey past the 20,000-byte ceiling.
  var currentPage = null;

  var EVENT_CODES = {
    change: "c",
    click: "k",
    input: "i",
    hidden: "h",
    visible: "v",
    window_blur: "b",
    window_focus: "f",
  };

  function fieldName(k) {
    return k === 0 ? config.field : config.field + "_" + (k + 1);
  }

  function byteLength(s) {
    if (typeof TextEncoder === "function") {
      return new TextEncoder().encode(s).length;
    }
    return unescape(encodeURIComponent(s)).length;
  }

  function readField(k) {
    var raw = Qualtrics.SurveyEngine.getJSEmbeddedData(fieldName(k));
    if (!raw) return [];

    try {
      var doc = JSON.parse(raw);
      return doc && doc.v === 2 && doc.p ? doc.p : [];
    } catch (e) {
      return [];
    }
  }

  function serialize(pages) {
    return JSON.stringify({ v: 2, p: pages });
  }

  function readAll() {
    var fields = [];
    for (var k = 0; k < config.maxFields; k++) fields.push(readField(k));
    return fields;
  }

  function countPages(fields) {
    var n = 0;
    for (var k = 0; k < fields.length; k++) n += fields[k].length;
    return n;
  }

  // Trim events off the end of `page` until `pages` plus it fits in one
  // field. Returns the trimmed copy, or null if not even the bare page fits.
  function fitPage(pages, page) {
    var copy = {};
    for (var key in page) copy[key] = page[key];
    copy.e = page.e.slice();

    var size = byteLength(serialize(pages.concat([copy])));
    while (size > config.maxBytes && copy.e.length) {
      // Each event is roughly 30 bytes; drop in batches so a very long page
      // does not cost one stringify per event.
      var excess = Math.ceil((size - config.maxBytes) / 30);
      copy.e.length = Math.max(0, copy.e.length - Math.max(1, excess));
      copy.d = page.e.length - copy.e.length;
      size = byteLength(serialize(pages.concat([copy])));
    }
    return size <= config.maxBytes ? copy : null;
  }

  // Store `page`, replacing any earlier copy of it. A page whose submit is
  // refused (a validation error, say) is submitted again from the same
  // `currentPage`, and that second save must not leave two copies behind.
  function savePage(page) {
    var fields = readAll();
    var k;
    var dirty = {};

    for (k = 0; k < fields.length; k++) {
      for (var j = fields[k].length - 1; j >= 0; j--) {
        if (fields[k][j].i === page.i) {
          fields[k].splice(j, 1);
          dirty[k] = true;
        }
      }
    }

    // Append to the newest non-empty field while the page fits whole.
    // Otherwise move on to the next field -- only one, so a single huge page
    // (trimmed there if it must be) cannot use up every remaining field. The
    // final field takes whatever fits.
    var last = 0;
    for (k = 0; k < fields.length; k++) if (fields[k].length) last = k;

    var placed = fitPage(fields[last], page);
    k = last;
    if ((!placed || placed.d) && last + 1 < fields.length) {
      k = last + 1;
      placed = fitPage(fields[k], page);
    }
    if (placed) {
      fields[k].push(placed);
      dirty[k] = true;
    }

    for (k in dirty) {
      Qualtrics.SurveyEngine.setJSEmbeddedData(
        fieldName(Number(k)),
        serialize(fields[k]),
      );
    }

    if (!placed) {
      log("page", page.i, "not stored: all", config.maxFields, "fields are full");
    } else if (placed.d) {
      log("page", page.i, "stored with", placed.d, "events trimmed");
    }
    return placed;
  }

  // Resolve the Qualtrics question id (e.g. "QID69", or a matrix statement
  // like "QID47-4") for an element. Radios/checkboxes carry it directly on
  // `name`; text/textarea inputs don't -- in the new survey-taking
  // experience they have no id or name at all, only an
  // `aria-labelledby="question-display-QIDn"` and a `question-QIDn` wrapper
  // -- so recover the QID from the element's own id/name, its
  // aria-labelledby, or the nearest ancestor whose id contains the QID.
  // Returning the id as `name` keeps every answer event in the shape the
  // downstream parser keys on.
  function resolveName(el) {
    if (el.name && /^QID\d/.test(el.name)) return el.name;

    var fromSelf = (el.id || el.name || "").match(/QID\d+(?:-\d+)?/);
    if (fromSelf) return fromSelf[0];

    var labelledby =
      (el.getAttribute && el.getAttribute("aria-labelledby")) || "";
    var fromAria = labelledby.match(/QID\d+(?:-\d+)?/);
    if (fromAria) return fromAria[0];

    var container = el.closest && el.closest('[id*="QID"]');
    if (container) {
      var fromContainer = container.id.match(/QID\d+(?:-\d+)?/);
      if (fromContainer) return fromContainer[0];
    }

    return el.name || null;
  }

  // ---- EVENT LOGGER ----
  // Events can also fire between a successful submit and the next page's
  // "ready" (a stray blur, say). They land on a page that has already been
  // saved and are lost unless that page is submitted again, which is fine.
  function pushEvent(type, name, inputType) {
    if (!currentPage) return;

    var event = [Date.now() - currentPage.t, EVENT_CODES[type] || type];
    if (name || inputType) event.push(name || null);
    if (inputType) event.push(inputType);

    currentPage.e.push(event);
    log({ type: type, ms: event[0], name: name, input_type: inputType });
  }

  function logEvent(type, el) {
    var name = null;
    var inputType = null;

    if (el) {
      if (el.type) inputType = el.type;
      name = resolveName(el);
    }

    pushEvent(type, name, inputType);
  }

  // ---- DEBOUNCE STATE (per element) ----
  var debounceMap = new WeakMap();

  function debounceInput(el) {
    if (!el) return;

    if (debounceMap.has(el)) {
      clearTimeout(debounceMap.get(el));
    }

    var timeoutId = setTimeout(function () {
      logEvent("input", el);
      debounceMap.delete(el);
    }, config.inputDebounceMs);

    debounceMap.set(el, timeoutId);
  }

  // ---- HELPERS ----
  function isTextLike(el) {
    if (!el || !el.tagName) return false;
    if (el.tagName === "TEXTAREA") return true;
    if (el.tagName === "INPUT") {
      return /^(text|email|number|search|tel|url|password)$/.test(el.type);
    }
    return false;
  }

  function isMeaningfulClick(el) {
    if (!el || !el.tagName) return false;
    // Only log clicks on things you actually "press": buttons and links.
    // Radio/checkbox selection is captured by `change`.
    if (el.tagName === "BUTTON" || el.tagName === "A") return true;
    if (el.tagName === "INPUT" && /^(button|submit)$/.test(el.type)) return true;
    return false;
  }

  // ---- DROP-DOWNS ----
  // New-experience drop-downs are an ARIA combobox -- a
  // <div role="combobox" id="QIDn"> backed by a <ul role="listbox"> of
  // <li role="option"> items -- with no native <select>, so picking a
  // value fires no change/input event. The widget also defeats a plain
  // bubble-phase click listener two ways: it commits the selection on
  // pointerdown/mousedown and unmounts the listbox (so no click is ever
  // dispatched on the option), and its own handlers may stopPropagation().
  // So every document listener below uses the CAPTURE phase, the option
  // press is logged on pointerdown (the first event a selection can
  // produce) with click kept as a fallback, and Enter on an expanded
  // combobox covers keyboard selection. logDropdownSelect() dedupes so a
  // single selection logs once, in the same shape as other inputs (type
  // "change", input_type "select", name = QID). Option ids look like
  // "menu-item-QIDn-<choice>", so prefer the QID from the owning
  // "question-QIDn" wrapper to drop the choice suffix.
  var lastDropdown = { name: null, t: 0 };

  function logDropdownSelect(el) {
    // The first option is a "Select one" placeholder whose id has an
    // empty choice suffix ("menu-item-QIDn-"). Picking it clears the
    // answer, so don't log it as one.
    if (/^menu-item-QID\d+-$/.test(el.id || "")) return;

    var wrapper = el.closest && el.closest('[id^="question-QID"]');
    var src = (wrapper && wrapper.id) || el.id || "";
    var match = src.match(/QID\d+/);
    if (!match) return;

    // Collapse pointerdown + fallback click (or Enter + synthetic click)
    // from one selection. question_timings() keys on min(time) per QID,
    // so a stray duplicate outside this window is harmless anyway.
    var t = Date.now();
    if (match[0] === lastDropdown.name && t - lastDropdown.t < 500) return;
    lastDropdown = { name: match[0], t: t };

    pushEvent("change", match[0], "select");
  }

  function optionFromEvent(e) {
    var el = e.target;
    return (el && el.closest && el.closest('[role="option"]')) || null;
  }

  // ---- INTERACTION TRACKING ----
  // Installed once per document, not once per page: in the new survey-taking
  // experience the document survives page transitions, so re-binding on every
  // "ready" would stack a fresh set of listeners on each page.
  function installListeners() {
    document.addEventListener(
      "pointerdown",
      function (e) {
        var option = optionFromEvent(e);
        if (option) logDropdownSelect(option);
      },
      true,
    );

    document.addEventListener(
      "click",
      function (e) {
        var option = optionFromEvent(e);
        if (option) {
          logDropdownSelect(option);
          return;
        }

        if (isMeaningfulClick(e.target)) logEvent("click", e.target);
      },
      true,
    );

    document.addEventListener(
      "keydown",
      function (e) {
        // Enter on an open combobox commits the highlighted option without
        // any pointer event. aria-expanded gates out the Enter that merely
        // opens the menu.
        if (e.key !== "Enter") return;
        var combo = e.target.closest && e.target.closest('[role="combobox"]');
        if (combo && combo.getAttribute("aria-expanded") === "true") {
          logDropdownSelect(combo);
        }
      },
      true,
    );

    document.addEventListener(
      "change",
      function (e) {
        // Canonical "user provided an answer" for radios, checkboxes,
        // selects, and (on blur) text fields.
        logEvent("change", e.target);
      },
      true,
    );

    document.addEventListener(
      "input",
      function (e) {
        // Only debounce real text entry. Radios/checkboxes also fire
        // `input` but `change` already covers them.
        if (isTextLike(e.target)) debounceInput(e.target);
      },
      true,
    );

    // ---- FOCUS / VISIBILITY ----
    document.addEventListener("visibilitychange", function () {
      logEvent(document.hidden ? "hidden" : "visible");
    });

    global.addEventListener("blur", function () {
      logEvent("window_blur");
    });

    global.addEventListener("focus", function () {
      logEvent("window_focus");
    });
  }

  // ---- PAGE LIFECYCLE ----
  function startPage() {
    var page = {
      i: countPages(readAll()),
      t: Date.now(),
      e: [],
    };
    currentPage = page;

    log("page", page.i, "loaded");

    // Bound to this page rather than to `currentPage`, so a late submit hook
    // can never save the next page's events under this page's index. The
    // page stays current after saving: if Qualtrics refuses the submit, the
    // respondent is still on it, and the next attempt saves it again.
    Qualtrics.SurveyEngine.addOnPageSubmit(function () {
      try {
        page.s = Date.now() - page.t;
        savePage(page);
        log("page", page.i, "submitted", page.e.length, "events");
      } catch (e) {
        // Never let a logging failure stop the respondent moving on.
        if (global.console) console.error("[survey-timing] save failed:", e);
      }
    });
  }

  // ---- BOOTSTRAP ----
  function engineReady() {
    return !!(
      global.Qualtrics &&
      Qualtrics.SurveyEngine &&
      typeof Qualtrics.SurveyEngine.addOnReady === "function"
    );
  }

  // An inline header script runs inside the Qualtrics bundle's own load
  // order; an external one may execute before it. Poll until the engine
  // exists rather than assuming it does.
  function whenEngineReady(callback) {
    if (engineReady()) return callback();

    var waited = 0;
    var interval = 50;
    var timer = setInterval(function () {
      if (engineReady()) {
        clearInterval(timer);
        callback();
        return;
      }

      waited += interval;
      if (waited >= config.engineTimeoutMs) {
        clearInterval(timer);
        if (global.console) {
          console.warn(
            "[survey-timing] Qualtrics.SurveyEngine never appeared; no timing data will be recorded.",
          );
        }
      }
    }, interval);
  }

  // Ask Qualtrics to start a page for us on the next "ready". Called once at
  // install, and again whenever the script is re-evaluated (see install()).
  function rearm() {
    whenEngineReady(function () {
      Qualtrics.SurveyEngine.addOnReady(startPage);
    });
  }

  function install() {
    // The script can run more than once in a single document: loaded from the
    // header and again from a question, or -- in the new survey-taking
    // experience, where the document survives page transitions -- the header
    // re-evaluated on each page. A second evaluation must not install a second
    // set of listeners (every event would be logged twice), and must not take
    // over from the live instance: the listeners already on the document write
    // into *its* closure, so a fresh copy would collect nothing. Hand the
    // ready hook back to it instead, in case Qualtrics dropped the previously
    // registered callback with the previous page.
    if (global.SurveyTiming && global.SurveyTiming.installed) {
      if (typeof global.SurveyTiming.rearm === "function") {
        global.SurveyTiming.rearm();
      }
      return;
    }

    readConfig();

    global.SurveyTiming = {
      version: VERSION,
      installed: true,
      config: config,
      rearm: rearm,
      // Console helpers for testing a survey: SurveyTiming.state() shows the
      // log written so far, SurveyTiming.page() the page in progress, and
      // SurveyTiming.bytes() how full each field is.
      state: function () {
        if (!engineReady()) return null;
        return readAll().reduce(function (all, pages) {
          return all.concat(pages);
        }, []);
      },
      bytes: function () {
        if (!engineReady()) return null;
        return readAll().map(function (pages, k) {
          return fieldName(k) + ": " + byteLength(serialize(pages));
        });
      },
      page: function () {
        return currentPage;
      },
    };

    whenEngineReady(function () {
      log("v" + VERSION + " initialized; field =", config.field);
      installListeners();
      Qualtrics.SurveyEngine.addOnReady(startPage);
    });
  }

  try {
    install();
  } catch (e) {
    // Never let a logging failure take the survey down with it.
    if (global.console) console.error("[survey-timing] failed to install:", e);
  }
})(window);
