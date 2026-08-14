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
 * The embedded data field must exist in the survey flow before it can be
 * written to. It defaults to `timing`; override it (and the text-input
 * debounce) with attributes on the script tag:
 *
 *   <script
 *     src="https://canadian-municipal-barometer.github.io/response-time-tools/survey-timing.js"
 *     data-field="timing"
 *     data-debounce="500"
 *     data-debug="false"
 *   ></script>
 */
(function (global) {
  "use strict";

  var VERSION = "1.0.0";

  // ---- CONFIG ----
  var config = {
    // Embedded data field the event log is written to.
    field: "timing",
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
    }

    // document.currentScript is the tag being executed; it is null when the
    // file is inlined or eval'd, in which case the defaults stand.
    var tag = document.currentScript;
    if (!tag || !tag.getAttribute) return;

    var field = tag.getAttribute("data-field");
    if (field) config.field = field;

    var debounce = parseInt(tag.getAttribute("data-debounce"), 10);
    if (!isNaN(debounce)) config.inputDebounceMs = debounce;

    if (tag.getAttribute("data-debug") === "true") config.debug = true;
  }

  function log() {
    if (!config.debug || !global.console) return;
    console.log.apply(console, ["[survey-timing]"].concat([].slice.call(arguments)));
  }

  // ---- STATE ----
  // `currentPage` is the page whose events are being collected right now. It
  // is swapped in by startPage() on every Qualtrics "ready" and cleared on
  // submit, so the document listeners below (installed once) always write to
  // the page actually on screen.
  var currentPage = null;

  function getState() {
    var raw = Qualtrics.SurveyEngine.getJSEmbeddedData(config.field);

    if (!raw) return { pages: [] };

    try {
      return JSON.parse(raw);
    } catch (e) {
      return { pages: [] };
    }
  }

  function setState(state) {
    Qualtrics.SurveyEngine.setJSEmbeddedData(config.field, JSON.stringify(state));
  }

  function now() {
    return new Date().toISOString();
  }

  function getPageIndex(state) {
    return state.pages.length;
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
  function pushEvent(event) {
    // Events can fire between a submit and the next page's "ready" (a stray
    // blur, say). The page they belong to has already been serialized, so
    // there is nowhere to put them.
    if (!currentPage) return;
    currentPage.events.push(event);
    log(event);
  }

  function logEvent(type, el) {
    var event = {
      type: type,
      time: now(),
    };

    if (el) {
      if (el.type) {
        event.input_type = el.type;
      }

      var name = resolveName(el);
      if (name) {
        event.name = name;
      }
    }

    pushEvent(event);
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

    pushEvent({
      type: "change",
      time: now(),
      input_type: "select",
      name: match[0],
    });
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
    var state = getState();

    currentPage = {
      page_index: getPageIndex(state),
      load_time: now(),
      events: [],
    };

    log("page", currentPage.page_index, "loaded");

    Qualtrics.SurveyEngine.addOnPageSubmit(function () {
      if (!currentPage) return;

      currentPage.submit_time = now();

      // Re-read rather than reusing the state captured at load: anything else
      // on the page may have written embedded data in the meantime.
      var latest = getState();
      latest.pages.push(currentPage);
      setState(latest);

      log("page", currentPage.page_index, "submitted", currentPage.events.length, "events");
      currentPage = null;
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
      // log written so far, SurveyTiming.page() the page in progress.
      state: function () {
        return engineReady() ? getState() : null;
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
