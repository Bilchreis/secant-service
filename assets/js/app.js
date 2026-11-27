// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/secant_service";
import topbar from "../vendor/topbar";

import { EChartsChart } from "./charts/echarts_chart";
import { ArraySpark, Sparkline } from "./charts/sparkline";

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

// Width of the module inspector, remembered per browser.
const INSPECTOR_KEY = "secant:inspector-width";
const INSPECTOR_MIN = 320;
// Leave room for the module rail and one narrow column of cards; the panel
// may take everything else. CSS caps it the same way on window resize.
// From xl the rail (15rem) is shown too; between lg and xl it is hidden.
const inspectorReserved = () => (window.innerWidth >= 1280 ? 544 : 288); // 34rem / 18rem
const inspectorMax = () => Math.max(INSPECTOR_MIN, window.innerWidth - inspectorReserved());
try {
  const saved = parseInt(localStorage.getItem(INSPECTOR_KEY), 10);
  if (saved >= INSPECTOR_MIN) {
    document.documentElement.style.setProperty("--inspector-w", `${saved}px`);
  }
} catch (_e) {
  // storage unavailable (private mode): keep the CSS default
}

let Hooks = {};

// Drag handle on the left edge of the inspector panel. The width is kept in a
// CSS variable on <html>, outside the LiveView DOM, so patches never reset it.
Hooks.ResizablePanel = {
  mounted() {
    const panel = this.el.parentElement;
    const setWidth = (w) => {
      const width = Math.round(Math.min(inspectorMax(), Math.max(INSPECTOR_MIN, w)));
      document.documentElement.style.setProperty("--inspector-w", `${width}px`);
      return width;
    };
    const save = (w) => {
      try { localStorage.setItem(INSPECTOR_KEY, String(w)); } catch (_e) {}
    };

    this._onDown = (e) => {
      e.preventDefault();
      const startX = e.clientX;
      const startW = panel.getBoundingClientRect().width;
      let last = startW;
      this.el.setPointerCapture(e.pointerId);
      document.body.style.userSelect = "none";
      const move = (ev) => { last = setWidth(startW + (startX - ev.clientX)); };
      const up = () => {
        this.el.removeEventListener("pointermove", move);
        this.el.removeEventListener("pointerup", up);
        this.el.removeEventListener("pointercancel", up);
        document.body.style.userSelect = "";
        save(last);
      };
      this.el.addEventListener("pointermove", move);
      this.el.addEventListener("pointerup", up);
      this.el.addEventListener("pointercancel", up);
    };
    this._onDblClick = () => {
      document.documentElement.style.removeProperty("--inspector-w");
      try { localStorage.removeItem(INSPECTOR_KEY); } catch (_e) {}
    };
    this._onKey = (e) => {
      if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
      e.preventDefault();
      const step = e.shiftKey ? 80 : 20;
      const w = panel.getBoundingClientRect().width + (e.key === "ArrowLeft" ? step : -step);
      save(setWidth(w));
    };
    this.el.addEventListener("pointerdown", this._onDown);
    this.el.addEventListener("dblclick", this._onDblClick);
    this.el.addEventListener("keydown", this._onKey);
  },
  destroyed() {
    this.el.removeEventListener("pointerdown", this._onDown);
    this.el.removeEventListener("dblclick", this._onDblClick);
    this.el.removeEventListener("keydown", this._onKey);
  },
};

Hooks.EChartsChart = EChartsChart;
Hooks.Sparkline = Sparkline;
Hooks.ArraySpark = ArraySpark;

window.addEventListener("phx:reveal-panel", (e) => {
  if (window.innerWidth >= 1024) return;
  const el = document.getElementById(e.detail.id);
  if (!el) return;
  const r = el.getBoundingClientRect();
  if (r.top < 0 || r.top > window.innerHeight * 0.5) el.scrollIntoView({ behavior: "smooth", block: "start" });
});

// CopyToClipboard hook for copying text with visual feedback
Hooks.CopyToClipboard = {
  mounted() {
    this.originalTooltip = this.el.dataset.tip;

    this.el.addEventListener("click", () => {
      const textToCopy = this.el.dataset.copy;

      navigator.clipboard
        .writeText(textToCopy)
        .then(() => {
          // Change tooltip to show success
          this.el.dataset.tip = "✓ Copied!";
          this.el.classList.add("tooltip-success");

          // Revert back after 2 seconds
          setTimeout(() => {
            this.el.dataset.tip = this.originalTooltip;
            this.el.classList.remove("tooltip-success");
          }, 2000);
        })
        .catch((err) => {
          console.error("Failed to copy:", err);
          // Show error feedback
          this.el.dataset.tip = "✗ Failed to copy";
          this.el.classList.add("tooltip-error");

          setTimeout(() => {
            this.el.dataset.tip = this.originalTooltip;
            this.el.classList.remove("tooltip-error");
          }, 2000);
        });
    });
  },
};

// Register hooks with LiveSocket
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { ...Hooks, ...colocatedHooks },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}
